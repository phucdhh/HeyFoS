#!/bin/bash

echo "🔧 Cloudflare DNS Configuration for HeyFoS"
echo "==========================================="
echo ""
echo "📋 Current Status:"
echo "   - Tunnel: heystack (ID: ec599d7a-b844-4d00-8bcf-4a573d13d5bd)"
echo "   - Config: /Users/mac/.cloudflared/heystack-config.yml"
echo "   - Domain: heyfos.truyenthong.edu.vn"
echo ""
echo "⚠️  DNS Record Already Exists"
echo ""
echo "Please update the DNS record manually on Cloudflare Dashboard:"
echo ""
echo "1. Go to: https://dash.cloudflare.com/"
echo "2. Select domain: truyenthong.edu.vn"
echo "3. Click 'DNS' → 'Records'"
echo "4. Find record: heyfos.truyenthong.edu.vn"
echo "5. Edit/Delete the existing record"
echo "6. Create new CNAME record:"
echo "   - Type: CNAME"
echo "   - Name: heyfos"
echo "   - Target: ec599d7a-b844-4d00-8bcf-4a573d13d5bd.cfargotunnel.com"
echo "   - Proxy status: Proxied (orange cloud)"
echo "   - TTL: Auto"
echo ""
echo "Or delete existing record via CLI:"
echo "   cloudflared tunnel route dns delete heyfos.truyenthong.edu.vn"
echo "   (Then run this script again)"
echo ""

# Check if tunnel is running
if ps aux | grep -v grep | grep "heystack-config.yml" > /dev/null; then
    echo "✅ Tunnel is running"
    echo ""
    echo "🌐 Testing connectivity in 10 seconds..."
    sleep 10
    
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" https://heyfos.truyenthong.edu.vn 2>/dev/null)
    
    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "301" ] || [ "$HTTP_CODE" = "302" ]; then
        echo "✅ heyfos.truyenthong.edu.vn is LIVE!"
        echo "   HTTP $HTTP_CODE"
    else
        echo "⚠️  Domain not yet accessible (HTTP $HTTP_CODE)"
        echo "   DNS may still be propagating (can take up to 5 minutes)"
    fi
else
    echo "❌ Tunnel is not running"
    echo ""
    echo "Start tunnel with:"
    echo "   nohup cloudflared tunnel --config /Users/mac/.cloudflared/heystack-config.yml run heystack > /tmp/heystack-tunnel.log 2>&1 &"
fi

echo ""
echo "📊 Check tunnel status:"
echo "   tail -f /tmp/heystack-tunnel.log"
echo ""
