#!/bin/bash

# HeyFoS - Status Script
# Checks the status of backend and frontend servers

BACKEND_PORT=7070
FRONTEND_PORT=7071
BACKEND_LOG="/tmp/heyfos-backend.log"
FRONTEND_LOG="/tmp/heyfos-frontend.log"
TUNNEL_LOG="/tmp/heyfos-tunnel.log"
TUNNEL_CONFIG="/Users/mac/.cloudflared/config-heyfos.yml"

echo "📊 HeyFoS Status"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Tunnel status
echo "🌐 Cloudflare Tunnel (heyfos):"
if TUNNEL_PID=$(pgrep -f "config-heyfos.yml" 2>/dev/null | head -1); then
    echo "   Status: ✅ RUNNING"
    echo "   PID: $TUNNEL_PID"
    if [ -f "$TUNNEL_LOG" ]; then
        CONN_COUNT=$(grep -c "Registered tunnel connection" "$TUNNEL_LOG" 2>/dev/null || echo 0)
        echo "   Connections: $CONN_COUNT registered"
        echo "   Last log entry:"
        tail -1 "$TUNNEL_LOG" | sed 's/^/      /'
    fi
else
    echo "   Status: ❌ NOT RUNNING"
    echo "   Start with: nohup cloudflared tunnel --config $TUNNEL_CONFIG run > $TUNNEL_LOG 2>&1 &"
fi

echo ""

# Backend status
echo "🔧 Backend Server (port $BACKEND_PORT):"
if BACKEND_PID=$(lsof -ti:$BACKEND_PORT 2>/dev/null); then
    echo "   Status: ✅ RUNNING"
    echo "   PID: $BACKEND_PID"
    
    # Get process info
    PS_INFO=$(ps -p $BACKEND_PID -o %cpu,%mem,etime,command 2>/dev/null | tail -1)
    echo "   Info: $PS_INFO"
    
    # Test API
    if curl -s -o /dev/null -w "%{http_code}" http://localhost:$BACKEND_PORT/health | grep -q "200"; then
        echo "   Health: ✅ API responding"
    else
        echo "   Health: ⚠️  API not responding"
    fi
    
    # Log file
    if [ -f "$BACKEND_LOG" ]; then
        echo "   Log: $BACKEND_LOG ($(wc -l < "$BACKEND_LOG" | tr -d ' ') lines)"
        echo "   Last log entry:"
        tail -1 "$BACKEND_LOG" | sed 's/^/      /'
    fi
else
    echo "   Status: ❌ NOT RUNNING"
fi

echo ""

# Frontend status
echo "🎨 Frontend Server (port $FRONTEND_PORT):"
if FRONTEND_PID=$(lsof -ti:$FRONTEND_PORT 2>/dev/null); then
    echo "   Status: ✅ RUNNING"
    echo "   PID: $FRONTEND_PID"
    
    # Get process info
    PS_INFO=$(ps -p $FRONTEND_PID -o %cpu,%mem,etime,command 2>/dev/null | tail -1)
    echo "   Info: $PS_INFO"
    
    # Check compilation status
    if [ -f "$FRONTEND_LOG" ]; then
        if grep -q "webpack compiled successfully" "$FRONTEND_LOG" 2>/dev/null; then
            echo "   Build: ✅ Compiled successfully"
        elif grep -q "Failed to compile" "$FRONTEND_LOG" 2>/dev/null; then
            echo "   Build: ❌ Compilation failed"
            echo "   Errors:"
            grep "ERROR" "$FRONTEND_LOG" | tail -3 | sed 's/^/      /'
        elif grep -q "webpack compiled with" "$FRONTEND_LOG" 2>/dev/null; then
            echo "   Build: ⚠️  Compiled with warnings"
        else
            echo "   Build: ⏳ Compiling..."
        fi
        
        echo "   Log: $FRONTEND_LOG ($(wc -l < "$FRONTEND_LOG" | tr -d ' ') lines)"
    fi
else
    echo "   Status: ❌ NOT RUNNING"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# System resources
echo "💻 System Resources:"
echo "   Memory: $(vm_stat | grep "Pages free" | awk '{print int($3 * 4096 / 1024 / 1024)}')MB free"
echo "   Load: $(sysctl -n vm.loadavg | awk '{print $2, $3, $4}')"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# URLs
echo "📍 Access URLs:"
if lsof -ti:$FRONTEND_PORT >/dev/null 2>&1; then
    echo "   Local:      http://localhost:$FRONTEND_PORT"
    if NETWORK_IP=$(ipconfig getifaddr en0 2>/dev/null); then
        echo "   Network:    http://$NETWORK_IP:$FRONTEND_PORT"
    fi
    echo "   Production: https://heyfos.truyenthong.edu.vn"
else
    echo "   ⚠️  Frontend not running - no access URLs available"
fi

if lsof -ti:$BACKEND_PORT >/dev/null 2>&1; then
    echo "   Backend:    http://localhost:$BACKEND_PORT"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Commands
echo "💡 Quick Commands:"
if lsof -ti:$FRONTEND_PORT >/dev/null 2>&1 || lsof -ti:$BACKEND_PORT >/dev/null 2>&1; then
    echo "   Stop:     ./stop.sh"
    echo "   Restart:  ./restart.sh"
    echo "   Logs:     tail -f $BACKEND_LOG"
    echo "             tail -f $FRONTEND_LOG"
else
    echo "   Start:    ./start.sh"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
