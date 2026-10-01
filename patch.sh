#!/bin/bash
# Z.ai Hosting Patcher — install the self-healing deploy kit into a project.
#
# Usage:
#   bash patch.sh [project-dir]           (default: current directory)
#   bash patch.sh --force [project-dir]   (skip .bak safety copies)
#
# What it does:
#   1. installs .zscripts/build.sh  — self-healing deploy-pipeline build
#   2. installs .zscripts/start.sh  — POSIX /app boot entry (FC contract)
#   3. creates .zscripts/cache/     — persistent fallback artifact home
#   4. ignores cache/log/backup files in .gitignore
#   5. runs doctor.sh for an immediate health report
set -eu

FORCE=0
TARGET=""
for a in "$@"; do
  case "$a" in
    --force|-f) FORCE=1 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) TARGET="$a" ;;
  esac
done
TARGET="${TARGET:-$PWD}"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ ! -f "$TARGET/package.json" ]; then
  echo "patch: $TARGET does not look like a Node project (no package.json)" >&2
  exit 1
fi

mkdir -p "$TARGET/.zscripts/cache"

install_one() {
  src="$1"; dst="$2"
  if [ -f "$dst" ] && ! cmp -s "$src" "$dst" && [ "$FORCE" != "1" ]; then
    cp -f "$dst" "$dst.bak.$(date +%Y%m%d%H%M%S)"
    echo "patch: backed up existing $(basename "$dst")"
  fi
  install -m 755 "$src" "$dst"
  echo "patch: installed $dst"
}

install_one "$SRC_DIR/templates/build.sh" "$TARGET/.zscripts/build.sh"
install_one "$SRC_DIR/templates/start.sh" "$TARGET/.zscripts/start.sh"

# .gitignore hygiene: build log + fallback artifact are machine state
touch "$TARGET/.gitignore"
for line in ".zscripts/cache/" ".zscripts/build.log" ".zscripts/*.bak.*"; do
  grep -qxF "$line" "$TARGET/.gitignore" || printf '%s\n' "$line" >> "$TARGET/.gitignore"
done
echo "patch: .gitignore updated"

echo "patch: running doctor"
bash "$SRC_DIR/doctor.sh" "$TARGET"
