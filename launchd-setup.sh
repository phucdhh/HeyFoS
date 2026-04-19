#!/bin/bash
# HeyFoS - LaunchDaemon Setup
# Run ONCE as root: sudo ./launchd-setup.sh
# Installs/updates all 3 daemons and bootstraps them into the system.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root: sudo $0" >&2
    exit 1
fi

HEYFOS_DIR="/Users/mac/HeyFoS"
DAEMON_DIR="/Library/LaunchDaemons"
LOG_DIR="$HEYFOS_DIR/logs"

mkdir -p "$LOG_DIR"
chmod +x "$HEYFOS_DIR/scripts/serve-frontend.sh"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  HeyFoS LaunchDaemon Setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── 1. Backend ────────────────────────────────────────────────────────────────
cat > "$DAEMON_DIR/com.heyfos.backend.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.heyfos.backend</string>

    <key>ProgramArguments</key>
    <array>
        <string>/Users/mac/HeyFoS/.build/release/heyfos-server</string>
        <string>serve</string>
        <string>--hostname</string>
        <string>0.0.0.0</string>
        <string>--port</string>
        <string>7070</string>
    </array>

    <key>WorkingDirectory</key>
    <string>/Users/mac/HeyFoS</string>

    <key>UserName</key>
    <string>mac</string>

    <key>GroupName</key>
    <string>staff</string>

    <key>StandardOutPath</key>
    <string>/Users/mac/HeyFoS/logs/backend.log</string>

    <key>StandardErrorPath</key>
    <string>/Users/mac/HeyFoS/logs/backend-error.log</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>HOME</key>
        <string>/Users/mac</string>
    </dict>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>

    <key>ThrottleInterval</key>
    <integer>10</integer>
</dict>
</plist>
PLIST
echo "✅ Written: com.heyfos.backend.plist"

# ── 2. Frontend ───────────────────────────────────────────────────────────────
cat > "$DAEMON_DIR/com.heyfos.frontend.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.heyfos.frontend</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/Users/mac/HeyFoS/scripts/serve-frontend.sh</string>
    </array>

    <key>WorkingDirectory</key>
    <string>/Users/mac/HeyFoS/frontend</string>

    <key>UserName</key>
    <string>mac</string>

    <key>GroupName</key>
    <string>staff</string>

    <key>StandardOutPath</key>
    <string>/Users/mac/HeyFoS/logs/frontend.log</string>

    <key>StandardErrorPath</key>
    <string>/Users/mac/HeyFoS/logs/frontend-error.log</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>HOME</key>
        <string>/Users/mac</string>
    </dict>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>

    <key>ThrottleInterval</key>
    <integer>10</integer>
</dict>
</plist>
PLIST
echo "✅ Written: com.heyfos.frontend.plist"

# ── 3. Cloudflare Tunnel ──────────────────────────────────────────────────────
cat > "$DAEMON_DIR/com.cloudflare.cloudflared.heyfos.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.cloudflare.cloudflared.heyfos</string>

    <key>ProgramArguments</key>
    <array>
        <string>/opt/homebrew/bin/cloudflared</string>
        <string>tunnel</string>
        <string>--config</string>
        <string>/Users/mac/.cloudflared/config-heyfos.yml</string>
        <string>run</string>
        <string>heyfos</string>
    </array>

    <key>UserName</key>
    <string>root</string>

    <key>StandardOutPath</key>
    <string>/Users/mac/HeyFoS/logs/cloudflared.log</string>

    <key>StandardErrorPath</key>
    <string>/Users/mac/HeyFoS/logs/cloudflared-error.log</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>/Users/mac</string>
    </dict>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>

    <key>ThrottleInterval</key>
    <integer>60</integer>
</dict>
</plist>
PLIST
echo "✅ Written: com.cloudflare.cloudflared.heyfos.plist"

# Fix log file ownership so daemon (mac user) can write to them
touch "$LOG_DIR/backend.log" "$LOG_DIR/backend-error.log" \
      "$LOG_DIR/frontend.log" "$LOG_DIR/frontend-error.log" \
      "$LOG_DIR/cloudflared.log" "$LOG_DIR/cloudflared-error.log"
chown mac:staff "$LOG_DIR"/*.log

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Loading daemons..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

_load_daemon() {
    local label="$1"
    local plist="$2"
    # Unload first if already in launchd (ignore errors)
    launchctl bootout "system/$label" 2>/dev/null || true
    sleep 1
    launchctl bootstrap system "$plist"
    echo "✅ Loaded: $label"
}

_load_daemon "com.heyfos.backend"               "$DAEMON_DIR/com.heyfos.backend.plist"
_load_daemon "com.heyfos.frontend"              "$DAEMON_DIR/com.heyfos.frontend.plist"
_load_daemon "com.cloudflare.cloudflared.heyfos" "$DAEMON_DIR/com.cloudflare.cloudflared.heyfos.plist"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  All HeyFoS daemons are installed and running."
echo "  Services will auto-start on every boot."
echo ""
echo "  Manage with:"
echo "    ./status.sh      — check status"
echo "    ./stop.sh        — stop all"
echo "    ./start.sh       — start all (if stopped)"
echo "    ./restart.sh     — restart all"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
