# HeyFoS Cloudflare Tunnel Configuration

## Thông tin Tunnel
- **Tunnel ID**: ec599d7a-b844-4d00-8bcf-4a573d13d5bd
- **Tunnel Name**: heyfos
- **Domain**: https://heyfos.truyenthong.edu.vn
- **Local Service**: http://localhost:7071 (Frontend React)

## Cấu hình

### Config File
Location: `/Users/mac/.cloudflared/heyfos-config.yml`

```yaml
tunnel: ec599d7a-b844-4d00-8bcf-4a573d13d5bd
credentials-file: /Users/mac/.cloudflared/ec599d7a-b844-4d00-8bcf-4a573d13d5bd.json

ingress:
  - hostname: heyfos.truyenthong.edu.vn
    path: ^/api/.*
    service: http://localhost:7070
  - hostname: heyfos.truyenthong.edu.vn
    service: http://localhost:7071
  - service: http_status:404
```

**Path-based Routing:**
- `/api/*` → Backend API (port 7070) 
- All other paths → Frontend (port 7071)

### Launch Agent
Location: `/Users/mac/Library/LaunchAgents/com.cloudflare.heyfos.plist`

Tunnel sẽ tự động khởi động khi Mac reboot.

## Quản lý Tunnel

### Khởi động thủ công
```bash
cloudflared tunnel --config /Users/mac/.cloudflared/heyfos-config.yml run heyfos
```

### Sử dụng Launch Agent
```bash
# Load service
launchctl load ~/Library/LaunchAgents/com.cloudflare.heyfos.plist

# Unload service
launchctl unload ~/Library/LaunchAgents/com.cloudflare.heyfos.plist

# Start service
launchctl start com.cloudflare.heyfos

# Stop service
launchctl stop com.cloudflare.heyfos
```

### Xem logs
```bash
# Output log
tail -f /Users/mac/.cloudflared/heyfos-tunnel.log

# Error log
tail -f /Users/mac/.cloudflared/heyfos-tunnel-error.log
```

## DNS Configuration
- Type: CNAME
- Name: heyfos.truyenthong.edu.vn
- Target: ec599d7a-b844-4d00-8bcf-4a573d13d5bd.cfargotunnel.com
- Status: Active

## Truy cập
Truy cập ứng dụng tại: **https://heyfos.truyenthong.edu.vn**

## Lưu ý
- Backend API (port 7070) được expose qua path `/api/*` trên cùng domain với frontend
- Frontend tự động detect production và sử dụng API URL không có port
- Tunnel credentials được lưu tại `/Users/mac/.cloudflared/ec599d7a-b844-4d00-8bcf-4a573d13d5bd.json`
- **Giữ file credentials bí mật!**
- Mixed Content issue đã được giải quyết bằng path-based routing
