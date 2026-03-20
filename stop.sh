#!/bin/bash

# HeyFoS - Stop Script
# Stops both backend and frontend servers

BACKEND_PORT=7070
FRONTEND_PORT=7071

echo "🛑 Stopping HeyFoS..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Stop backend
if lsof -ti:$BACKEND_PORT >/dev/null 2>&1; then
    echo "🔧 Stopping backend server (port $BACKEND_PORT)..."
    lsof -ti:$BACKEND_PORT | xargs kill -TERM 2>/dev/null
    
    # Wait for graceful shutdown
    sleep 2
    
    # Force kill if still running
    if lsof -ti:$BACKEND_PORT >/dev/null 2>&1; then
        echo "   Force killing backend..."
        lsof -ti:$BACKEND_PORT | xargs kill -9 2>/dev/null
    fi
    echo "   Backend stopped ✅"
else
    echo "⚠️  Backend not running"
fi

# Stop frontend
if lsof -ti:$FRONTEND_PORT >/dev/null 2>&1; then
    echo "🎨 Stopping frontend server (port $FRONTEND_PORT)..."
    lsof -ti:$FRONTEND_PORT | xargs kill -TERM 2>/dev/null
    
    # Wait for graceful shutdown
    sleep 2
    
    # Force kill if still running
    if lsof -ti:$FRONTEND_PORT >/dev/null 2>&1; then
        echo "   Force killing frontend..."
        lsof -ti:$FRONTEND_PORT | xargs kill -9 2>/dev/null
    fi
    echo "   Frontend stopped ✅"
else
    echo "⚠️  Frontend not running"
fi

# Stop Cloudflare tunnel
if pgrep -f "config-heyfos.yml" >/dev/null 2>&1; then
    echo "🌐 Stopping Cloudflare tunnel (heyfos)..."
    pkill -f "config-heyfos.yml" 2>/dev/null || true
    sleep 1
    echo "   Tunnel stopped ✅"
else
    echo "⚠️  Tunnel not running"
fi

# Clean up any remaining node/npm processes related to heyfos
pkill -f "heyfos-server" 2>/dev/null || true
pkill -f "frontend.*npm start" 2>/dev/null || true

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ HeyFoS stopped successfully!"
echo ""
echo "💡 Start again with: ./start.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
