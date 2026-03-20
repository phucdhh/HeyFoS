#!/bin/bash
# Watchdog: auto-restart backend if it crashes
BACKEND_LOG="/tmp/heyfos-backend.log"
BACKEND_PORT=7070
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while true; do
    if ! lsof -ti:$BACKEND_PORT >/dev/null 2>&1; then
        echo "[$(date)] Backend not running on port $BACKEND_PORT, restarting..." >> /tmp/heyfos-watchdog.log
        cd "$SCRIPT_DIR"
        nohup swift run heyfos-server serve --hostname 0.0.0.0 --port $BACKEND_PORT >> "$BACKEND_LOG" 2>&1 &
        sleep 20  # allow time for startup before next check
    fi
    sleep 10
done
