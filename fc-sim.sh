#!/bin/bash
# Z.ai Hosting Patcher — FC boot simulation.
# Reproduces what the deploy platform does after upload: extract the artifact
# into a scratch dir, boot it with `sh start.sh` (dash-compatible), then
# health-check / the way FC does — but on an unprivileged port, because in
# the dev sandbox the platform's own caddy occupies 81 and non-root binds
# get EACCES there. Production still uses FC_CUSTOM_LISTEN_PORT=81.
#
# Usage:
#   bash fc-sim.sh                              # pack cwd project and simulate
#   bash fc-sim.sh /path/to/project-dir         # pack that project and simulate
#   bash fc-sim.sh /path/to/artifact.tar.gz     # simulate a given artifact
#   FC_SIM_PORT=3101 bash fc-sim.sh ...         # override the sim port
#
# PASS = / returned HTTP 200 within the FC health window (120s).
set -eu

SIM_PORT="${FC_SIM_PORT:-3101}"
ARG="${1:-}"
TMP=""
SRV_PID=""

cleanup() {
  if [ -n "$SRV_PID" ]; then kill "$SRV_PID" 2>/dev/null || true; fi
  if [ -n "$TMP" ]; then rm -rf "$TMP"; fi
}
trap cleanup EXIT

if [ -n "$ARG" ] && [ -f "$ARG" ] && case "$ARG" in *.tar.gz|*.tgz) true ;; *) false ;; esac; then
  ART="$ARG"
else
  PROJ="${ARG:-$PWD}"
  if [ ! -f "$PROJ/.zscripts/build.sh" ]; then
    echo "fc-sim: no artifact given and $PROJ/.zscripts/build.sh missing (run patch.sh first)" >&2
    exit 1
  fi
  BUILD_ID="fcsim-$$" bash "$PROJ/.zscripts/build.sh"
  ART="/tmp/build_fullstack_fcsim-$$.tar.gz"
fi

[ -f "$ART" ] || { echo "fc-sim: build produced no artifact" >&2; exit 1; }

TMP=$(mktemp -d)
tar -xzf "$ART" -C "$TMP"
[ -f "$TMP/start.sh" ] || { echo "fc-sim: artifact has no start.sh at tar root (Case 03 — CAExited in production)" >&2; exit 1; }
[ -f "$TMP/server.js" ] || { echo "fc-sim: artifact has no server.js at tar root (not a Next standalone bundle?)" >&2; exit 1; }

cd "$TMP"
FC_CUSTOM_LISTEN_PORT="$SIM_PORT" sh start.sh > "$TMP/boot.log" 2>&1 &
SRV_PID=$!

echo "fc-sim: booting artifact on 127.0.0.1:$SIM_PORT (FC-style 120s health window)"
i=0
while [ "$i" -lt 120 ]; do
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 3 "http://127.0.0.1:$SIM_PORT/" || true)
  if [ "$code" = "200" ]; then
    echo "fc-sim: PASS — / returned 200 after ${i}s"
    head -4 "$TMP/boot.log" || true
    exit 0
  fi
  if ! kill -0 "$SRV_PID" 2>/dev/null; then
    echo "fc-sim: FAIL — boot process exited early; log tail:" >&2
    tail -20 "$TMP/boot.log" >&2
    exit 1
  fi
  sleep 1
  i=$((i + 1))
done
echo "fc-sim: FAIL — no HTTP 200 within 120s (would be CAExited in production); log tail:" >&2
tail -20 "$TMP/boot.log" >&2
exit 1
