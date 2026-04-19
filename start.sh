#!/bin/bash
# HeyFoS - Start Script
# Starts all HeyFoS services via LaunchDaemons (requires sudo for launchctl).

DAEMON_DIR="/Library/LaunchDaemons"
LABELS=(
    "com.heyfos.backend"
    "com.heyfos.frontend"
    "com.cloudflare.cloudflared.heyfos"
)
PLISTS=(
    "$DAEMON_DIR/com.heyfos.backend.plist"
    "$DAEMON_DIR/com.heyfos.frontend.plist"
    "$DAEMON_DIR/com.cloudflare.cloudflared.heyfos.plist"
)
NAMES=("🔧 Backend (port 7070)" "🎨 Frontend (port 7071)" "🌐 Cloudflare Tunnel")

BACKEND_PORT=7070
FRONTEND_PORT=7071

echo "🚀 Starting HeyFoS..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Verify plists are installed
MISSING=0
for plist in "${PLISTS[@]}"; do
    if [[ ! -f "$plist" ]]; then
        echo "❌ Missing plist: $plist"
        MISSING=1
    fi
done
if [[ $MISSING -eq 1 ]]; then
    echo ""
    echo "Run the one-time setup first:"
    echo "  sudo /Users/mac/HeyFoS/launchd-setup.sh"
    exit 1
fi

for i in "${!LABELS[@]}"; do
    label="${LABELS[$i]}"
    plist="${PLISTS[$i]}"
    name="${NAMES[$i]}"

    echo -n "  ${name}: "

    # Check if already loaded and running
    pid=$(sudo launchctl list "$label" 2>/dev/null | awk '/"PID"/{gsub(/[^0-9]/,"",$3); print $3}')
    if [[ -n "$pid" && "$pid" -gt 0 ]]; then
        echo "⚠️  already running (PID $pid)"
        continue
    fi

    # If loaded but not running → kickstart; if not loaded → bootstrap
    if sudo launchctl list "$label" &>/dev/null; then
        sudo launchctl kickstart "system/$label" &>/dev/null
    else
        sudo launchctl bootstrap system "$plist"
    fi
    echo "✅ started"
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
sleep 3
echo "📍 Access URLs:"
if lsof -ti:$FRONTEND_PORT >/dev/null 2>&1; then
    IP=$(ipconfig getifaddr en0 2>/dev/null || echo "N/A")
    echo "   Local:      http://localhost:$FRONTEND_PORT"
    echo "   Network:    http://$IP:$FRONTEND_PORT"
    echo "   Production: https://heyfos.truyenthong.edu.vn"
else
    echo "   ⏳ Frontend not up yet — check with: ./status.sh"
fi
echo "   Backend API: http://localhost:$BACKEND_PORT"
echo ""
echo "💡 Logs:    tail -f /Users/mac/HeyFoS/logs/backend.log"
echo "   Status:  ./status.sh"
echo "   Stop:    ./stop.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
