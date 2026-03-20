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

# Check if already running
if lsof -ti:$BACKEND_PORT >/dev/null 2>&1; then
    echo "⚠️  Backend already running on port $BACKEND_PORT"
else
    echo "🔧 Starting backend server..."
    cd "$SCRIPT_DIR"
    nohup swift run heyfos-server serve --hostname 0.0.0.0 --port $BACKEND_PORT > "$BACKEND_LOG" 2>&1 &
    BACKEND_PID=$!
    echo "   Backend PID: $BACKEND_PID"
    echo "   Log file: $BACKEND_LOG"
    
    # Wait for backend to build and start
    echo -n "   Building backend (this may take 2-3 minutes on first run)"
    for i in {1..180}; do
        if lsof -ti:$BACKEND_PORT >/dev/null 2>&1; then
            echo " ✅"
            break
        fi
        # Check if build is progressing
        if [ $((i % 10)) -eq 0 ]; then
            if grep -q "Building for debugging" "$BACKEND_LOG" 2>/dev/null; then
                PROGRESS=$(tail -1 "$BACKEND_LOG" | grep -oE '\[[0-9]+/[0-9]+\]' | tail -1)
                if [ -n "$PROGRESS" ]; then
                    echo -n " $PROGRESS"
                else
                    echo -n "."
                fi
            else
                echo -n "."
            fi
        fi
        sleep 1
    done
    
    if ! lsof -ti:$BACKEND_PORT >/dev/null 2>&1; then
        echo " ⚠️"
        echo "   Backend build may still be in progress. Check log: $BACKEND_LOG"
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
