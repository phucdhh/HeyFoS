#!/bin/bash
# HeyFoS - Stop Script
# Stops all HeyFoS services via LaunchDaemons (requires sudo for launchctl).

LABELS=(
    "com.heyfos.backend"
    "com.heyfos.frontend"
    "com.cloudflare.cloudflared.heyfos"
)
NAMES=("🔧 Backend" "🎨 Frontend" "🌐 Cloudflare Tunnel")

echo "🛑 Stopping HeyFoS..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

for i in "${!LABELS[@]}"; do
    label="${LABELS[$i]}"
    name="${NAMES[$i]}"
    echo -n "  ${name}: "
    if sudo launchctl list "$label" &>/dev/null; then
        sudo launchctl bootout "system/$label" 2>/dev/null && echo "✅ stopped" || echo "⚠️  already stopped"
    else
        echo "⚠️  not loaded"
    fi
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ HeyFoS stopped."
echo "   Start again with: ./start.sh"
