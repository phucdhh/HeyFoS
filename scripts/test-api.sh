#!/bin/bash

# Test HeyFoS API with sample upload

echo "🧪 Testing HeyFoS API"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Test 1: Health check
echo "1️⃣ Testing health endpoint..."
HEALTH=$(curl -s http://localhost:7070/health)
if echo "$HEALTH" | grep -q "ok"; then
    echo "   ✅ Backend is healthy"
    echo "   Response: $HEALTH"
else
    echo "   ❌ Backend not responding"
    exit 1
fi

echo ""

# Test 2: Create stack with file upload
echo "2️⃣ Testing file upload..."

# Find a test image
TEST_FILE=$(find /Users/mac/HeyFoS/tiff-samples -name "*.TIF" -o -name "*.tif" | head -1)

if [ -z "$TEST_FILE" ]; then
    echo "   ⚠️  No test files found in tiff-samples/"
    echo "   Please add some .TIF files to test"
    exit 1
fi

echo "   Using test file: $(basename $TEST_FILE)"
echo "   File size: $(du -h "$TEST_FILE" | cut -f1)"

# Upload file
RESPONSE=$(curl -s -X POST http://localhost:7070/api/stacks/create \
    -F "files=@$TEST_FILE")

echo "   Response: $RESPONSE"

if echo "$RESPONSE" | grep -q "stackId"; then
    STACK_ID=$(echo "$RESPONSE" | grep -o '"stackId":"[^"]*"' | cut -d'"' -f4)
    echo "   ✅ Upload successful"
    echo "   Stack ID: $STACK_ID"
    
    # Check if files were saved
    UPLOAD_DIR="/tmp/heyfos/uploads/$STACK_ID"
    if [ -d "$UPLOAD_DIR" ]; then
        FILE_COUNT=$(ls -1 "$UPLOAD_DIR" | wc -l)
        echo "   ✅ Files saved to disk: $FILE_COUNT file(s)"
        echo "   Directory: $UPLOAD_DIR"
        ls -lh "$UPLOAD_DIR"
    else
        echo "   ⚠️  Upload directory not found"
    fi
else
    echo "   ❌ Upload failed"
    exit 1
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ All tests passed!"
echo ""
echo "💡 Next steps:"
echo "   1. Open browser: http://localhost:7071"
echo "   2. Upload images via UI"
echo "   3. Check browser console for debug logs"
echo "   4. Check backend logs: tail -f /tmp/heyfos-backend.log"
