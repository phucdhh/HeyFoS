#!/bin/bash
# HeyFoS Tunnel Management Script

TUNNEL_NAME="heyfos"
TUNNEL_ID="ec599d7a-b844-4d00-8bcf-4a573d13d5bd"
CONFIG_FILE="/Users/mac/.cloudflared/heyfos-config.yml"
LOG_FILE="/Users/mac/.cloudflared/heyfos-tunnel.log"

case "$1" in
    start)
        echo "Starting HeyFoS tunnel..."
        if pgrep -f "cloudflared.*heyfos" > /dev/null; then
            echo "❌ Tunnel is already running!"
            exit 1
        fi
        nohup cloudflared tunnel --config "$CONFIG_FILE" run "$TUNNEL_NAME" > "$LOG_FILE" 2>&1 &
        sleep 3
        if pgrep -f "cloudflared.*heyfos" > /dev/null; then
            echo "✅ Tunnel started successfully!"
            echo "📊 Checking connections..."
            cloudflared tunnel info "$TUNNEL_NAME"
        else
            echo "❌ Failed to start tunnel. Check logs:"
            tail -20 "$LOG_FILE"
        fi
        ;;
    
    stop)
        echo "Stopping HeyFoS tunnel..."
        pkill -f "cloudflared.*heyfos"
        sleep 2
        if pgrep -f "cloudflared.*heyfos" > /dev/null; then
            echo "❌ Failed to stop tunnel"
            exit 1
        else
            echo "✅ Tunnel stopped successfully"
        fi
        ;;
    
    restart)
        $0 stop
        sleep 2
        $0 start
        ;;
    
    status)
        if pgrep -f "cloudflared.*heyfos" > /dev/null; then
            echo "✅ HeyFoS tunnel is running"
            echo ""
            cloudflared tunnel info "$TUNNEL_ID"
        else
            echo "❌ HeyFoS tunnel is not running"
            exit 1
        fi
        ;;
    
    logs)
        if [ -f "$LOG_FILE" ]; then
            tail -f "$LOG_FILE"
        else
            echo "❌ Log file not found: $LOG_FILE"
            exit 1
        fi
        ;;
    
    test)
        echo "Testing HeyFoS tunnel..."
        echo "🌐 Public URL: https://heyfos.truyenthong.edu.vn"
        echo "🏠 Local URL: http://localhost:7071"
        echo ""
        echo "Testing connection..."
        if curl -s -o /dev/null -w "%{http_code}" https://heyfos.truyenthong.edu.vn | grep -q "200"; then
            echo "✅ Tunnel is accessible!"
        else
            echo "⚠️  Tunnel might not be fully ready yet"
        fi
        ;;
    
    *)
        echo "HeyFoS Tunnel Management"
        echo ""
        echo "Usage: $0 {start|stop|restart|status|logs|test}"
        echo ""
        echo "Commands:"
        echo "  start    - Start the tunnel"
        echo "  stop     - Stop the tunnel"
        echo "  restart  - Restart the tunnel"
        echo "  status   - Check tunnel status"
        echo "  logs     - View tunnel logs (real-time)"
        echo "  test     - Test tunnel connectivity"
        exit 1
        ;;
esac
