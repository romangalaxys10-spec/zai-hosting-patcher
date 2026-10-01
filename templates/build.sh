#!/bin/bash
# Z.ai Hosting Patcher — self-healing deploy-pipeline build script.
# Installed to <project>/.zscripts/build.sh by patch.sh. Project-agnostic:
# works for any Next.js app deployed on z.ai fullstack hosting.
#
# Measured pipeline contract (reverse-engineered from z.ai fullstack deploys):
#   1. The platform runs this file with BUILD_ID=<id> in the environment and
#      may kill it after roughly ~14s.
#   2. When this script exits (or is killed), the pipeline requires the build
#      artifact at: /tmp/build_fullstack_${BUILD_ID}.tar.gz
#      Missing artifact -> deploy error.
#   3. The artifact must be a SELF-BOOTING app dir: the platform extracts it
#      to /app/ and runs `sh /app/start.sh`, then health-checks
#      FC_CUSTOM_LISTEN_PORT (81) within 120s. Unhealthy boot => CAExited.
#
# Strategy: a full `next build` (40s+ cold) cannot run inside the kill window,
# so builds happen DETACHED (double-fork orphan, survives any pipeline kill)
# and are kept warm; this script packs the latest finished standalone build
# synchronously and exits 0 fast.
#
# Self-healing (see CASES.md in the patcher repo):
#   - Case 04 (pack/rebuild race): pack FIRST, kick the rebuild AFTER.
#   - Case 05 (restart wipe): sandbox restarts wipe untracked build state
#     (.next/, logs). A standalone-less call ships the persistent fallback
#     artifact (.zscripts/cache/last-good.tar.gz) instead of failing, and
#     kicks a detached rebuild for freshness. With no standalone AND no
#     fallback it rebuilds and waits — that click may still fail, the next
#     one succeeds.
#
# Knobs (environment):
#   ZHP_DB_FILE       DB file to ship (default: db/custom.db, else prisma URL)
#   ZHP_WATCH_PATHS   paths watched for "source newer than build" freshness
set -e

APP_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$APP_DIR"

LOG="$APP_DIR/.zscripts/build.log"
STANDALONE="$APP_DIR/.next/standalone"
FALLBACK_DIR="$APP_DIR/.zscripts/cache"
FALLBACK="$FALLBACK_DIR/last-good.tar.gz"
WATCH_PATHS="${ZHP_WATCH_PATHS:-src app pages public prisma next.config.ts package.json}"

# Re-exec as z when invoked as root — keeps node_modules/.next ownership sane
# so the z-user dev server can still write afterwards.
if [ "$(id -u)" = "0" ] && id z > /dev/null 2>&1; then
  exec su z -c "bash $APP_DIR/.zscripts/build.sh"
fi

mkdir -p "$APP_DIR/.zscripts" "$FALLBACK_DIR"

complete_standalone() {
  [ -f "$STANDALONE/server.js" ] && [ -d "$STANDALONE/.next/static" ]
}

# ---- package manager + build commands (worker mode) ----
if [ -f bun.lock ] || [ -f bun.lockb ]; then PM=bun; else PM=npm; fi
install_once() {
  if [ "$PM" = "bun" ]; then bun install; else npm install; fi
}
build_once() {
  if [ "$PM" = "bun" ]; then bun run build; else npm run build; fi
}
db_push_once() {
  # best effort; only meaningful for prisma projects
  [ -f prisma/schema.prisma ] || return 0
  if [ "$PM" = "bun" ]; then
    bun run db:push 2>/dev/null || npx prisma db push
  else
    npx prisma db push
  fi
}

# ---- detect the DB file to ship (best effort, optional) ----
detect_db() {
  if [ -n "${ZHP_DB_FILE:-}" ] && [ -f "$ZHP_DB_FILE" ]; then printf '%s\n' "$ZHP_DB_FILE"; return 0; fi
  if [ -f "$APP_DIR/db/custom.db" ]; then printf '%s\n' "$APP_DIR/db/custom.db"; return 0; fi
  # prisma DATABASE_URL in .env (file:./dev.db resolves relative to prisma/)
  if [ -f "$APP_DIR/prisma/schema.prisma" ] && [ -f "$APP_DIR/.env" ]; then
    url=$(sed -n 's/^DATABASE_URL=//p' "$APP_DIR/.env" | head -1 | tr -d '\r' | tr -d '"')
    case "$url" in
      file:*)
        p=${url#file:}
        case "$p" in
          ./*) p="$APP_DIR/prisma/${p#./}" ;;
          /*) : ;;
          *) p="$APP_DIR/$p" ;;
        esac
        [ -f "$p" ] && printf '%s\n' "$p" && return 0
        ;;
    esac
  fi
  return 1
}

# pack <target.tar.gz> — assemble the SELF-BOOTING app dir and tar it.
pack() {
  # a) boot entry — POSIX sh, must sit at the tar root
  install -m 755 "$APP_DIR/.zscripts/start.sh" "$STANDALONE/start.sh"

  # b) DB, ready to run (prisma CLI is not part of the standalone bundle, so
  #    the schema cannot be pushed at boot — the file must arrive ready) and
  #    a normalized .env so the extracted copy points at /app, not the sandbox
  if db=$(detect_db); then
    rel=${db#"$APP_DIR/"}
    mkdir -p "$STANDALONE/$(dirname "$rel")"
    cp -f "$db" "$STANDALONE/$rel"
    printf 'DATABASE_URL=file:/app/%s\n' "$rel" > "$STANDALONE/.env"
  fi

  # c) z-ai sdk config (SDK reads $cwd/.z-ai-config first)
  if [ -r /etc/.z-ai-config ]; then
    cp -f /etc/.z-ai-config "$STANDALONE/.z-ai-config"
  else
    printf '{"baseUrl": "https://internal-api.z.ai/v1", "apiKey": "Z.ai"}\n' > "$STANDALONE/.z-ai-config"
  fi

  tar -czf "$1" -C "$STANDALONE" .
}

kick_rebuild() {
  if ! pgrep -f "next build" > /dev/null 2>&1; then
    ZBUILD_BG=1 setsid bash "$0" >> "$LOG" 2>&1 < /dev/null &
    disown 2>/dev/null || true
  fi
}

refresh_fallback() {
  cp -f "$1" "$FALLBACK.tmp" && mv -f "$FALLBACK.tmp" "$FALLBACK"
}

# ---------------- worker mode (detached background build) ----------------
if [ "${ZBUILD_BG:-}" = "1" ]; then
  {
    echo "[bg] === worker start $(date -u +%FT%TZ) (user $(id -un)) ==="
    if install_once; then echo "[bg] install ok $(date -u +%T)"; else echo "[bg] INSTALL FAILED"; fi
    if db_push_once; then echo "[bg] db ok $(date -u +%T)"; else echo "[bg] DB PUSH FAILED"; fi
    if build_once; then
      echo "[bg] BUILD OK $(date -u +%FT%TZ)"
      # keep the persistent fallback current so a future restart-wipe ships
      # instantly on the first deploy click instead of erroring
      if complete_standalone; then
        if pack "$FALLBACK.tmp"; then
          mv -f "$FALLBACK.tmp" "$FALLBACK"
          echo "[bg] fallback artifact refreshed ($(du -h "$FALLBACK" | cut -f1))"
        else
          echo "[bg] FALLBACK PACK FAILED"
        fi
      fi
    else
      echo "[bg] BUILD FAILED $(date -u +%FT%TZ) (previous standalone stays in place; inspect this log)"
    fi
  } >> "$LOG" 2>&1
  exit 0
fi

# ---------------- pipeline mode (artifact must exist on exit) ----------------
echo "=== build request $(date -u +%FT%TZ) (invoker: $(id -un), pid $$) ===" >> "$LOG"

OUT="/tmp/build_fullstack_${BUILD_ID:-$(date +%s)}.tar.gz"

# ORDER IS LOAD-BEARING: pack FIRST, kick rebuild AFTER (Case 04).
if complete_standalone; then
  pack "$OUT"
  refresh_fallback "$OUT"
  echo "[build.sh] artifact ready: $OUT ($(du -h "$OUT" | cut -f1)) at $(date -u +%T)" >> "$LOG"

  # freshness check (AFTER packing — see the ORDER note above): if source
  # changed after the last finished build, kick a detached rebuild so the
  # NEXT deploy call ships the fresh code. This call ships what exists.
  newest_src=""
  for p in $WATCH_PATHS; do
    [ -e "$APP_DIR/$p" ] || continue
    hit=$(find "$p" -type f -newer "$STANDALONE/server.js" 2>/dev/null | head -1 || true)
    if [ -n "$hit" ]; then newest_src="$hit"; break; fi
  done
  if [ -n "$newest_src" ]; then
    echo "[build.sh] source newer than build (e.g. $newest_src) — kicking detached rebuild" >> "$LOG"
    kick_rebuild
  fi

  exit 0
fi

# -------- self-heal: standalone missing (restart wipe, Case 05) --------
if [ -f "$FALLBACK" ]; then
  echo "[build.sh] standalone missing — shipping persistent fallback ($(du -h "$FALLBACK" | cut -f1), code as of its pack time)" >> "$LOG"
  cp -f "$FALLBACK" "$OUT"
  echo "[build.sh] kicking detached rebuild to restore fresh standalone" >> "$LOG"
  kick_rebuild
  exit 0
fi

# Last resort: no standalone, no fallback. Kick the rebuild (survives the
# pipeline kill) and wait — if this environment lets us run long enough we
# can still finish; if the pipeline kills us, the next deploy click works.
echo "[build.sh] standalone AND fallback missing — self-heal: rebuild + wait" >> "$LOG"
kick_rebuild
i=0
while [ "$i" -lt 300 ]; do
  if complete_standalone; then
    pack "$OUT"
    refresh_fallback "$OUT"
    echo "[build.sh] self-healed: artifact ready after $((i * 2))s wait: $OUT ($(du -h "$OUT" | cut -f1))" >> "$LOG"
    exit 0
  fi
  sleep 2
  i=$((i + 1))
done

echo "[build.sh] FATAL: no standalone and no fallback, rebuild did not finish in wait window" >> "$LOG"
exit 1
