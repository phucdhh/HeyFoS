# HeyFoS Cloudflare Tunnel Setup - DNS Update Required

## Current Status

✅ **Tunnel Configuration Updated**
- Tunnel ID: `ec599d7a-b844-4d00-8bcf-4a573d13d5bd`
- Config File: `/Users/mac/.cloudflared/heystack-config.yml`
- Hostname: `heyfos.truyenthong.edu.vn`
- Status: **Running** ✅

✅ **Backend Services**
- API Server: `http://localhost:7070` (needs to be started)
- Frontend: `http://localhost:7071` (needs to be started)

## ⚠️ Action Required: Update DNS Record

The DNS record `heyfos.truyenthong.edu.vn` already exists but needs to be updated to point to the correct tunnel.

### Option 1: Cloudflare Dashboard (Recommended)

1. Go to: **https://dash.cloudflare.com/**
2. Select domain: **truyenthong.edu.vn**
3. Navigate to: **DNS → Records**
4. Find: **heyfos.truyenthong.edu.vn**
5. Click **Edit** or **Delete** the existing record
6. Create/Update CNAME record with:
   ```
   Type:   CNAME
   Name:   heyfos
   Target: ec599d7a-b844-4d00-8bcf-4a573d13d5bd.cfargotunnel.com
   Proxy:  On (orange cloud enabled)
   TTL:    Auto
   ```
7. Click **Save**

### Option 2: Command Line (if you have Cloudflare API token)

```bash
# First, delete existing record
cloudflared tunnel route dns delete heyfos.truyenthong.edu.vn

# Then create new route
cloudflared tunnel route dns ec599d7a-b844-4d00-8bcf-4a573d13d5bd heyfos.truyenthong.edu.vn
```

## Verify Setup

After updating DNS (wait 1-2 minutes for propagation):

```bash
# Check DNS resolution
dig heyfos.truyenthong.edu.vn CNAME +short

# Test HTTP access
curl -I https://heyfos.truyenthong.edu.vn

# Check tunnel logs
tail -f /tmp/heystack-tunnel.log
```

## Start HeyFoS Services

```bash
# Start backend API
swift run heyfos-api

# In another terminal, start frontend
cd frontend && npm start
```

## Tunnel Management

```bash
# Check tunnel status
ps aux | grep cloudflared | grep heystack

# View logs
tail -f /tmp/heystack-tunnel.log

# Stop tunnel
kill $(ps aux | grep "heystack-config.yml" | grep -v grep | awk '{print $2}')

# Restart tunnel
nohup cloudflared tunnel --config /Users/mac/.cloudflared/heystack-config.yml run heystack > /tmp/heystack-tunnel.log 2>&1 &
```

## Summary

| Component | Status | Address |
|-----------|--------|---------|
| Cloudflare Tunnel | ✅ Running | - |
| DNS Record | ⚠️ Needs Update | heyfos.truyenthong.edu.vn |
| API Server | ⏸️ Not Started | http://localhost:7070 |
| Frontend | ⏸️ Not Started | http://localhost:7071 |
| Public URL | ⏳ Pending DNS | https://heyfos.truyenthong.edu.vn |

Once DNS is updated and services are started, HeyFoS will be accessible at:
**https://heyfos.truyenthong.edu.vn** 🚀
