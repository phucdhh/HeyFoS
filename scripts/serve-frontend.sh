#!/bin/bash
# Wrapper to run the 'serve' static file server for HeyFoS frontend.
# Called by com.heyfos.frontend LaunchDaemon.

BUILD_DIR="/Users/mac/HeyFoS/frontend/build"
NODE="/opt/homebrew/bin/node"
SERVE_JS=$(find /opt/homebrew/Cellar/node -path "*/serve/build/main.js" 2>/dev/null | head -1)

if [[ -z "$SERVE_JS" ]]; then
    echo "ERROR: serve module not found. Run: npm install -g serve" >&2
    exit 1
fi

exec "$NODE" "$SERVE_JS" --single --listen 7071 "$BUILD_DIR"
