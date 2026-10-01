#!/bin/bash
# Z.ai Hosting Patcher — detect the known deployment failure modes.
# Usage: bash doctor.sh [project-dir]     (default: current directory)
# Exit 0 = no FAIL-level issues; exit 1 = at least one FAIL (deploy will break).
set -u
TARGET="${1:-$PWD}"
PASS=0; WARN=0; FAIL=0
ok()   { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
warn() { printf '  [WARN] %s\n' "$1"; WARN=$((WARN+1)); }
bad()  { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "Z.ai Hosting Patcher doctor — $TARGET"

# --- project sanity -------------------------------------------------------
if [ -f "$TARGET/package.json" ]; then
  ok "package.json present"
  if TARGET="$TARGET" node -e 'const p=require(process.env.TARGET+"/package.json"); process.exit(p.scripts&&p.scripts.build?0:1)' 2>/dev/null; then
    ok "package.json has scripts.build"
  else
    bad "package.json lacks scripts.build (pipeline build cannot produce the standalone)"
  fi
else
  bad "package.json missing (is this the right directory?)"
fi

# --- Case 01: missing build.sh --------------------------------------------
if [ -f "$TARGET/.zscripts/build.sh" ]; then
  if bash -n "$TARGET/.zscripts/build.sh" 2>/dev/null; then
    ok ".zscripts/build.sh parses (bash)"
  else
    bad ".zscripts/build.sh has syntax errors"
  fi
else
  bad ".zscripts/build.sh missing — deploy pipeline produces no artifact (run patch.sh)"
fi

# --- Case 03: missing / non-POSIX start.sh --------------------------------
if [ -f "$TARGET/.zscripts/start.sh" ]; then
  if sh -n "$TARGET/.zscripts/start.sh" 2>/dev/null; then
    ok ".zscripts/start.sh parses as POSIX sh"
  else
    bad ".zscripts/start.sh is NOT POSIX-sh safe (FC boots it with dash -> CAExited)"
  fi
  if command -v dash > /dev/null 2>&1; then
    if dash -n "$TARGET/.zscripts/start.sh" 2>/dev/null; then
      ok ".zscripts/start.sh parses under dash"
    else
      bad ".zscripts/start.sh fails dash parse (FC runs dash)"
    fi
  fi
  grep -q "FC_CUSTOM_LISTEN_PORT" "$TARGET/.zscripts/start.sh" \
    && ok "start.sh honors FC_CUSTOM_LISTEN_PORT" \
    || warn "start.sh does not reference FC_CUSTOM_LISTEN_PORT (health check may target the wrong port)"
else
  bad ".zscripts/start.sh missing — deploy boots with 'cannot open /app/start.sh' CAExited (run patch.sh)"
fi

# --- Case 05: standalone / fallback state ---------------------------------
if [ -f "$TARGET/.next/standalone/server.js" ] && [ -d "$TARGET/.next/standalone/.next/static" ]; then
  ok "warm standalone build present"
else
  warn "no finished standalone build — first deploy click self-heals via fallback/rebuild"
fi
if [ -f "$TARGET/.zscripts/cache/last-good.tar.gz" ]; then
  ok "persistent fallback artifact present ($(du -h "$TARGET/.zscripts/cache/last-good.tar.gz" | cut -f1))"
else
  warn "no fallback artifact yet (created automatically after the first successful pack)"
fi

# --- DB readiness ----------------------------------------------------------
if [ -f "$TARGET/prisma/schema.prisma" ] && [ ! -f "$TARGET/db/custom.db" ] && [ ! -f "$TARGET/prisma/dev.db" ]; then
  warn "prisma schema found but no ready DB file — the artifact will ship without one (prisma CLI is absent at boot)"
fi

# --- build log: only the MOST RECENT build request matters -----------------
LOG="$TARGET/.zscripts/build.log"
if [ -f "$LOG" ]; then
  last_req=$(awk '/=== build request/{ln=NR} END{print ln+0}' "$LOG")
  if [ "$last_req" -gt 0 ] && tail -n "+$last_req" "$LOG" | grep -q "FATAL"; then
    bad "latest build request ended FATAL — inspect: tail -20 $LOG"
  else
    ok "latest build request has no FATAL entries"
  fi
fi

echo "doctor: $PASS pass, $WARN warn, $FAIL fail"
if [ "$FAIL" -eq 0 ]; then
  exit 0
fi
exit 1
