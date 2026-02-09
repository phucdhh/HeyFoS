# HeyFoS Testing Guide

## Current Issue Analysis

### Problem
- Production URL (https://heyfos.truyenthong.edu.vn/) serves development build
- WebSocket connections fail because dev server not accessible externally
- Thumbnails not showing due to JavaScript errors from WebSocket failures

### Solution

## Testing Steps

### 1. Test Locally (Recommended First)
```bash
# Open in browser:
http://localhost:7071

# This will:
- Connect to local webpack-dev-server properly
- Show all console.log() debug messages
- Display thumbnails correctly
- Enable React DevTools
```

### 2. Upload Test Images
```bash
# Use sample images from:
/Users/mac/HeyFoS/tiff-samples/

# What to watch:
- Browser Console (F12 → Console tab)
- Network tab (F12 → Network tab)
- Processing Console in app
- Backend logs: tail -f /tmp/heyfos-backend.log
```

### 3. Expected Console Output
```
ImageViewer: images changed 19
Creating object URLs for 19 images
Created URL for _RAM4253.TIF : blob:http://localhost:7071/...
...
ImageUrls set: [...]
Rendering 19 thumbnails
Thumbnail 1 loaded
Thumbnail 2 loaded
...
```

### 4. Backend Logs to Watch
```bash
tail -f /tmp/heyfos-backend.log
```

Expected output when uploading:
```
📦 Creating stack: <uuid>
📁 Upload directory created: /tmp/heyfos/uploads/<uuid>
📋 Content-Type: multipart/form-data; boundary=...
📋 Decoded X files from 'files' field
[1/X] 💾 Saving filename.TIF (12345678 bytes)
  ✅ Saved
...
✅ Successfully uploaded X files
```

## Production Deployment (TODO)

For production, need to:

1. **Build frontend for production**
```bash
cd /Users/mac/HeyFoS/frontend
npm run build
```

2. **Serve static build via backend or nginx**
   - Option A: Serve via Vapor (add static file middleware)
   - Option B: Use nginx/caddy to serve build/ folder
   - Option C: Deploy to Vercel/Netlify with backend API separate

3. **Update Cloudflare Tunnel config**
   - Point to production server (not dev server)
   - Ensure proper port mapping

## Quick Commands

```bash
# Start servers
./start.sh

# Check status
./status.sh

# View logs
tail -f /tmp/heyfos-backend.log
tail -f /tmp/heyfos-frontend.log

# Stop servers
./stop.sh

# Test backend API
curl http://localhost:7070/health

# Test from production domain
curl https://heyfos.truyenthong.edu.vn/api/health
```

## Debugging Thumbnails Issue

If thumbnails still don't show on localhost:7071:

1. **Check Browser Console**
   - Look for "ImageViewer: images changed"
   - Look for "Created URL for..."
   - Look for image load errors

2. **Check Network Tab**
   - Filter by "XHR/Fetch"
   - Look for /api/stacks/create request
   - Check response body

3. **Check Backend**
   - Is it receiving files?
   - Are files being saved to disk?
   - Check /tmp/heyfos/uploads/<stackId>/

4. **Common Issues**
   - CORS: Backend should allow localhost:7071
   - File permissions: Check /tmp/heyfos/ is writable
   - Memory: Large files may cause issues
