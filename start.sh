#!/bin/bash

# HeyFoS - Start Script
# Starts both backend and frontend servers

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_LOG="/tmp/heyfos-backend.log"
FRONTEND_LOG="/tmp/heyfos-frontend.log"
TUNNEL_LOG="/tmp/heyfos-tunnel.log"
TUNNEL_CONFIG="/Users/mac/.cloudflared/config-heyfos.yml"
BACKEND_PORT=7070
FRONTEND_PORT=7071

echo "🚀 Starting HeyFoS..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Determine which backend binary to use
# Prefer pre-built release binary (fast start); fall back to swift run (slow but always works)
RELEASE_BIN="$SCRIPT_DIR/.build/release/heyfos-server"
DEBUG_BIN="$SCRIPT_DIR/.build/debug/heyfos-server"

if [ -x "$RELEASE_BIN" ]; then
    BACKEND_CMD="$RELEASE_BIN"
    echo "   Using pre-built release binary (fast start)"
elif [ -x "$DEBUG_BIN" ]; then
    BACKEND_CMD="$DEBUG_BIN"
    echo "   Using pre-built debug binary"
else
    BACKEND_CMD="swift run heyfos-server"
    echo "   No pre-built binary found — building now (first run may take 2-3 min)"
    echo "   Tip: run './build.sh' first for instant startup next time."
fi

# Check if already running
if lsof -ti:$BACKEND_PORT >/dev/null 2>&1; then
    echo "⚠️  Backend already running on port $BACKEND_PORT"
else
    echo "🔧 Starting backend server..."
    cd "$SCRIPT_DIR"
    nohup $BACKEND_CMD > "$BACKEND_LOG" 2>&1 &
    BACKEND_PID=$!
    echo "   Backend PID: $BACKEND_PID"
    echo "   Log file: $BACKEND_LOG"
    
    # Wait for backend to start (release binary starts in ~1s vs 2-3 min for swift run)
    WAIT_SECS=180
    echo -n "   Waiting for backend to start"
    for i in $(seq 1 $WAIT_SECS); do
        if lsof -ti:$BACKEND_PORT >/dev/null 2>&1; then
            echo " ✅ (${i}s)"
            break
        fi
        if [ $((i % 10)) -eq 0 ]; then
            echo -n "."
        fi
        sleep 1
    done
    
    if ! lsof -ti:$BACKEND_PORT >/dev/null 2>&1; then
        echo " ⚠️"
        echo "   Backend may still be building. Check log: $BACKEND_LOG"
        echo "   Run './status.sh' to check if it started later."
    fi
fi

# Check if frontend already running
if lsof -ti:$FRONTEND_PORT >/dev/null 2>&1; then
    echo "⚠️  Frontend already running on port $FRONTEND_PORT"
else
    echo "🎨 Starting frontend server (static build)..."
    cd "$SCRIPT_DIR/frontend"
    SERVE_BIN=$(command -v serve 2>/dev/null || echo "/opt/homebrew/Cellar/node/25.7.0/bin/serve")
    nohup "$SERVE_BIN" -s build -l $FRONTEND_PORT > "$FRONTEND_LOG" 2>&1 &
    FRONTEND_PID=$!
    echo "   Frontend PID: $FRONTEND_PID"
    echo "   Log file: $FRONTEND_LOG"
    
    # Wait for server to start
    echo -n "   Waiting for frontend to start"
    for i in {1..20}; do
        if grep -q "Accepting connections" "$FRONTEND_LOG" 2>/dev/null; then
            echo " ✅"
            break
        fi
        echo -n "."
        sleep 1
    done
    
    if ! grep -q "Accepting connections" "$FRONTEND_LOG" 2>/dev/null; then
        echo " ⚠️"
        echo "   Frontend may still be starting. Check log: $FRONTEND_LOG"
    fi
fi

# Start Cloudflare tunnel
echo "🌐 Starting Cloudflare tunnel (heyfos)..."
if pgrep -f "config-heyfos.yml" >/dev/null 2>&1; then
    echo "⚠️  Tunnel already running"
else
    nohup cloudflared tunnel --config "$TUNNEL_CONFIG" run > "$TUNNEL_LOG" 2>&1 &
    TUNNEL_PID=$!
    echo "   Tunnel PID: $TUNNEL_PID"
    echo -n "   Waiting for connections"
    for i in {1..20}; do
        if grep -q "Registered tunnel connection" "$TUNNEL_LOG" 2>/dev/null; then
            echo " ✅"
            break
        fi
        echo -n "."
        sleep 1
    done
    if ! grep -q "Registered tunnel connection" "$TUNNEL_LOG" 2>/dev/null; then
        echo " ⚠️  Tunnel may still be connecting. Check log: $TUNNEL_LOG"
    fi
fi

# Start watchdog to auto-restart backend on crash
pkill -f watchdog.sh 2>/dev/null
nohup bash "$SCRIPT_DIR/watchdog.sh" >> /tmp/heyfos-watchdog.log 2>&1 &
echo "🐕 Watchdog PID: $!"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✨ HeyFoS started successfully!"
echo ""
echo "📍 Access URLs:"
echo "   Local:      http://localhost:$FRONTEND_PORT"
echo "   Network:    http://$(ipconfig getifaddr en0 2>/dev/null || echo "N/A"):$FRONTEND_PORT"
echo "   Production: https://heyfos.truyenthong.edu.vn"
echo ""
echo "📊 Backend API: http://localhost:$BACKEND_PORT"
echo ""
echo "💡 Tips:"
echo "   - Check status:  ./status.sh"
echo "   - View logs:     tail -f $BACKEND_LOG"
echo "   - Tunnel logs:   tail -f $TUNNEL_LOG"
echo "   - Stop servers:  ./stop.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
