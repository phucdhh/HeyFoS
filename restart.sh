#!/bin/bash
# HeyFoS - Restart Script
# Restarts all HeyFoS services via LaunchDaemons (requires sudo for launchctl).

LABELS=(
    "com.heyfos.backend"
    "com.heyfos.frontend"
    "com.cloudflare.cloudflared.heyfos"
)
NAMES=("🔧 Backend" "🎨 Frontend" "🌐 Cloudflare Tunnel")
DAEMON_DIR="/Library/LaunchDaemons"
PLISTS=(
    "$DAEMON_DIR/com.heyfos.backend.plist"
    "$DAEMON_DIR/com.heyfos.frontend.plist"
    "$DAEMON_DIR/com.cloudflare.cloudflared.heyfos.plist"
)

echo "🔄 Restarting HeyFoS..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

for i in "${!LABELS[@]}"; do
    label="${LABELS[$i]}"
    plist="${PLISTS[$i]}"
    name="${NAMES[$i]}"
    echo -n "  ${name}: "
    if sudo launchctl list "$label" &>/dev/null; then
        # Already loaded — use kickstart -k (kill then restart)
        sudo launchctl kickstart -k "system/$label" &>/dev/null && echo "✅ restarted"
    else
        # Not loaded — bootstrap it
        sudo launchctl bootstrap system "$plist" && echo "✅ started (was not loaded)"
    fi
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ HeyFoS restarted."
echo "   Check with: ./status.sh"
