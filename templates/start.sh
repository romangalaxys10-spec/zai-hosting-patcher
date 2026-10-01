#!/bin/sh
# Z.ai Hosting Patcher — published-instance boot entry.
# Installed to <project>/.zscripts/start.sh; build.sh packs it at the tar
# root of the artifact. The deploy pipeline extracts the artifact into /app/
# and the FC runtime executes:  sh /app/start.sh
#
# Boot contract (learned from the FC CAExited error + image inspection):
#   - MUST stay POSIX-sh compatible (dash runs it) — no bashisms.
#   - FC health-checks FC_CUSTOM_LISTEN_PORT (81) within 120s and expects
#     HTTP 200; first non-healthy pass kills the deploy ("CAExited").
#   - The artifact dir next to this script contains the Next.js standalone
#     bundle (server.js, .next/, public, node_modules) and, when the project
#     uses a database, a ready-to-run DB file plus a normalized .env.
#
# This script must never exit: it execs the server in the foreground.
set -e

APP_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$APP_DIR"

# 1. z-ai-web-dev-sdk config. SDK resolution order: $cwd/.z-ai-config,
#    ~/.z-ai-config, /etc/.z-ai-config. build.sh ships it in the artifact;
#    write the platform-standard stub as a fallback.
if [ ! -f .z-ai-config ]; then
  printf '{"baseUrl": "https://internal-api.z.ai/v1", "apiKey": "Z.ai"}\n' > .z-ai-config
fi

# 2. Database (optional): the artifact ships it ready and .env carries the
#    /app-normalized DATABASE_URL. Export it explicitly (belt and suspenders
#    — Next standalone also loads .env itself) and make the file writable for
#    whatever uid runs the server.
DB_URL=$(sed -n 's/^DATABASE_URL=//p' .env 2>/dev/null | head -1 | tr -d '\r' | tr -d '"')
case "$DB_URL" in
  file:*)
    DB_PATH=${DB_URL#file:}
    case "$DB_PATH" in
      /*) : ;;
      *) DB_PATH="$APP_DIR/$DB_PATH" ;;
    esac
    mkdir -p "$(dirname "$DB_PATH")"
    [ -f "$DB_PATH" ] || : > "$DB_PATH"
    if [ "$(id -u)" = "0" ]; then
      chmod -R a+rwX "$(dirname "$DB_PATH")" 2>/dev/null || true
    fi
    export DATABASE_URL="$DB_URL"
    ;;
esac

# 3. Runtime env. Next standalone reads PORT and HOSTNAME; FC routes to
#    FC_CUSTOM_LISTEN_PORT.
export NODE_ENV=production
export PORT="${FC_CUSTOM_LISTEN_PORT:-81}"
export HOSTNAME=0.0.0.0

# 4. Serve. node is present in the FC image; bun as a fallback.
if command -v node > /dev/null 2>&1; then
  exec node server.js
else
  exec bun server.js
fi
