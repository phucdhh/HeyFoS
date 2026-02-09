#!/bin/bash

# HeyFoS - Restart Script
# Restarts both backend and frontend servers

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "🔄 Restarting HeyFoS..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Stop servers
"$SCRIPT_DIR/stop.sh"

echo ""
echo "⏳ Waiting 3 seconds before restart..."
sleep 3
echo ""

# Start servers
"$SCRIPT_DIR/start.sh"
