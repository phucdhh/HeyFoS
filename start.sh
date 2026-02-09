#!/bin/bash

# HeyFoS - Start Script
# Starts both backend and frontend servers

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_LOG="/tmp/heyfos-backend.log"
FRONTEND_LOG="/tmp/heyfos-frontend.log"
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
    
    # Wait for backend to start
    echo -n "   Waiting for backend to start"
    for i in {1..30}; do
        if lsof -ti:$BACKEND_PORT >/dev/null 2>&1; then
            echo " ✅"
            break
        fi
        echo -n "."
        sleep 1
    done
    
    if ! lsof -ti:$BACKEND_PORT >/dev/null 2>&1; then
        echo " ❌"
        echo "   Failed to start backend. Check log: $BACKEND_LOG"
        exit 1
    fi
fi

# Check if frontend already running
if lsof -ti:$FRONTEND_PORT >/dev/null 2>&1; then
    echo "⚠️  Frontend already running on port $FRONTEND_PORT"
else
    echo "🎨 Starting frontend server..."
    cd "$SCRIPT_DIR/frontend"
    PORT=$FRONTEND_PORT nohup npm start > "$FRONTEND_LOG" 2>&1 &
    FRONTEND_PID=$!
    echo "   Frontend PID: $FRONTEND_PID"
    echo "   Log file: $FRONTEND_LOG"
    
    # Wait for frontend to compile
    echo -n "   Waiting for frontend to compile"
    for i in {1..60}; do
        if grep -q "webpack compiled" "$FRONTEND_LOG" 2>/dev/null; then
            echo " ✅"
            break
        fi
        echo -n "."
        sleep 1
    done
    
    if ! grep -q "webpack compiled" "$FRONTEND_LOG" 2>/dev/null; then
        echo " ⚠️"
        echo "   Frontend may still be compiling. Check log: $FRONTEND_LOG"
    fi
fi

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
echo "   - Stop servers:  ./stop.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
