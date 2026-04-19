#!/bin/bash
# HeyFoS - Status Script
# Shows status of all HeyFoS services. No sudo required.

BACKEND_PORT=7070
FRONTEND_PORT=7071
LOG_DIR="/Users/mac/HeyFoS/logs"

echo "📊 HeyFoS Status"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Cloudflare Tunnel ─────────────────────────────────────────────────────────
echo ""
echo "🌐 Cloudflare Tunnel (com.cloudflare.cloudflared.heyfos):"
TUNNEL_PID=$(pgrep -f "config-heyfos.yml" 2>/dev/null | head -1)
if [[ -n "$TUNNEL_PID" ]]; then
    echo "   Status: ✅ RUNNING (PID $TUNNEL_PID)"
    TUNNEL_LOGFILE="$LOG_DIR/cloudflared-error.log"
    if [[ -f "$TUNNEL_LOGFILE" ]]; then
        CONN=$(grep -c "Registered tunnel connection" "$TUNNEL_LOGFILE" 2>/dev/null || true)
        [[ -z "$CONN" ]] && CONN=0
        echo "   Connections: $CONN registered (from last start)"
        LAST=$(grep "Registered tunnel connection" "$TUNNEL_LOGFILE" 2>/dev/null | tail -1)
        [[ -n "$LAST" ]] && echo "   Last conn:   $LAST"
    fi
else
    echo "   Status: ❌ NOT RUNNING"
    echo "   Daemon: check with: sudo launchctl print system/com.cloudflare.cloudflared.heyfos"
fi

# ── Backend ───────────────────────────────────────────────────────────────────
echo ""
echo "🔧 Backend Server (port $BACKEND_PORT) (com.heyfos.backend):"
BACKEND_PID=$(lsof -ti:$BACKEND_PORT 2>/dev/null | head -1)
if [[ -n "$BACKEND_PID" ]]; then
    echo "   Status: ✅ RUNNING (PID $BACKEND_PID)"
    PS_INFO=$(ps -p "$BACKEND_PID" -o %cpu,%mem,etime 2>/dev/null | tail -1 | xargs)
    [[ -n "$PS_INFO" ]] && echo "   CPU/Mem/Uptime: $PS_INFO"
    if curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://localhost:$BACKEND_PORT/health" | grep -q "200"; then
        echo "   Health: ✅ API responding"
    else
        echo "   Health: ⚠️  API not responding"
    fi
    if [[ -f "$LOG_DIR/backend.log" ]]; then
        echo "   Log:    $LOG_DIR/backend.log ($(wc -l < "$LOG_DIR/backend.log" | tr -d ' ') lines)"
        echo "   Last entry: $(tail -1 "$LOG_DIR/backend.log")"
    fi
else
    echo "   Status: ❌ NOT RUNNING"
    if [[ -f "$LOG_DIR/backend-error.log" ]]; then
        echo "   Last error: $(tail -2 "$LOG_DIR/backend-error.log")"
    fi
fi

# ── Frontend ──────────────────────────────────────────────────────────────────
echo ""
echo "🎨 Frontend Server (port $FRONTEND_PORT) (com.heyfos.frontend):"
FRONTEND_PID=$(lsof -ti:$FRONTEND_PORT 2>/dev/null | head -1)
if [[ -n "$FRONTEND_PID" ]]; then
    echo "   Status: ✅ RUNNING (PID $FRONTEND_PID)"
    PS_INFO=$(ps -p "$FRONTEND_PID" -o %cpu,%mem,etime 2>/dev/null | tail -1 | xargs)
    [[ -n "$PS_INFO" ]] && echo "   CPU/Mem/Uptime: $PS_INFO"
    if [[ -f "$LOG_DIR/frontend.log" ]]; then
        echo "   Log:    $LOG_DIR/frontend.log ($(wc -l < "$LOG_DIR/frontend.log" | tr -d ' ') lines)"
        echo "   Last entry: $(tail -1 "$LOG_DIR/frontend.log")"
    fi
else
    echo "   Status: ❌ NOT RUNNING"
    if [[ -f "$LOG_DIR/frontend-error.log" ]]; then
        echo "   Last error: $(tail -2 "$LOG_DIR/frontend-error.log")"
    fi
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "💻 System Resources:"
echo "   Memory: $(vm_stat | awk '/Pages free/{printf "%dMB free\n", int($3 * 4096 / 1024 / 1024)}')"
echo "   Load:   $(sysctl -n vm.loadavg | awk '{print $2, $3, $4}')"
echo ""
echo "📍 Access URLs:"
if [[ -n "$FRONTEND_PID" ]]; then
    IP=$(ipconfig getifaddr en0 2>/dev/null || echo "N/A")
    echo "   Local:      http://localhost:$FRONTEND_PORT"
    echo "   Network:    http://$IP:$FRONTEND_PORT"
    echo "   Production: https://heyfos.truyenthong.edu.vn"
else
    echo "   ⚠️  Frontend not running"
fi
echo ""
echo "💡 Quick Commands:"
echo "   sudo ./stop.sh     — stop all services"
echo "   sudo ./restart.sh  — restart all services"
echo "   tail -f $LOG_DIR/backend.log"
echo "   tail -f $LOG_DIR/cloudflared.log"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
