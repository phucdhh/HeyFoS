#!/bin/bash

# Test HeyFoS API with TIFF samples
echo "=== Testing HeyFoS with 19 TIFF samples (12MP each) ==="

USER_ID="test-$(date +%s)"
SESSION_ID="session-$(date +%s)"
API_URL="http://localhost:7070"

echo "User ID: $USER_ID"
echo "Session ID: $SESSION_ID"
echo ""

# Create upload directory
UPLOAD_DIR="./users/$USER_ID/$SESSION_ID/upload"
mkdir -p "$UPLOAD_DIR"

# Copy TIFF files
echo "Copying 19 TIFF files..."
cp tiff-samples/*.TIF "$UPLOAD_DIR/"
echo "✓ Files copied"

# Create stack
echo ""
echo "Creating stack..."
STACK_RESPONSE=$(curl -s -X POST "$API_URL/api/stacks/create" \
  -H "X-User-ID: $USER_ID" \
  -H "X-Session-ID: $SESSION_ID" \
  -F "files[]=@$UPLOAD_DIR/_RAM4253.TIF" \
  -F "files[]=@$UPLOAD_DIR/_RAM4254.TIF" \
  -F "files[]=@$UPLOAD_DIR/_RAM4255.TIF" \
  -F "files[]=@$UPLOAD_DIR/_RAM4256.TIF" \
  -F "files[]=@$UPLOAD_DIR/_RAM4257.TIF" \
  -F "files[]=@$UPLOAD_DIR/_RAM4258.TIF" \
  -F "files[]=@$UPLOAD_DIR/_RAM4259.TIF" \
  -F "files[]=@$UPLOAD_DIR/_RAM4260.TIF" \
  -F "files[]=@$UPLOAD_DIR/_RAM4261.TIF" \
  -F "files[]=@$UPLOAD_DIR/_RAM4262.TIF" \
  -F "files[]=@$UPLOAD_DIR/_RAM4263.TIF" \
  -F "files[]=@$UPLOAD_DIR/_RAM4264.TIF" \
  -F "files[]=@$UPLOAD_DIR/_RAM4265.TIF" \
  -F "files[]=@$UPLOAD_DIR/_RAM4266.TIF" \
  -F "files[]=@$UPLOAD_DIR/_RAM4267.TIF" \
  -F "files[]=@$UPLOAD_DIR/_RAM4268.TIF" \
  -F "files[]=@$UPLOAD_DIR/_RAM4269.TIF" \
  -F "files[]=@$UPLOAD_DIR/_RAM4270.TIF" \
  -F "files[]=@$UPLOAD_DIR/_RAM4271.TIF")

echo "$STACK_RESPONSE" | jq '.'
STACK_ID=$(echo "$STACK_RESPONSE" | jq -r '.stackId')

if [ "$STACK_ID" = "null" ]; then
  echo "❌ Failed to create stack"
  exit 1
fi

echo "✓ Stack created: $STACK_ID"

# Start processing
echo ""
echo "Starting processing (PyBlend, 4 levels, 10MP output)..."
START_TIME=$(date +%s)

PROCESS_RESPONSE=$(curl -s -X POST "$API_URL/api/stacks/$STACK_ID/process" \
  -H "Content-Type: application/json" \
  -d '{
    "depthMapAlgorithm": "max",
    "blendingAlgorithm": "pyramid",
    "pyramidLevels": 4,
    "blurRadius": 1
  }')

echo "$PROCESS_RESPONSE" | jq '.'
JOB_ID=$(echo "$PROCESS_RESPONSE" | jq -r '.jobId')

echo "✓ Job started: $JOB_ID"

# Poll status
echo ""
echo "Polling job status..."
while true; do
  sleep 2
  STATUS=$(curl -s "$API_URL/api/jobs/$JOB_ID/status")
  
  STATE=$(echo "$STATUS" | jq -r '.status')
  PROGRESS=$(echo "$STATUS" | jq -r '.progress')
  MESSAGE=$(echo "$STATUS" | jq -r '.message')
  
  echo "[$PROGRESS%] $MESSAGE"
  
  if [ "$STATE" = "completed" ]; then
    END_TIME=$(date +%s)
    ELAPSED=$((END_TIME - START_TIME))
    echo ""
    echo "=== COMPLETED in ${ELAPSED}s ==="
    
    # Download result
    RESULT_PATH="./test-result-$(date +%Y%m%d-%H%M%S).tiff"
    curl -s "$API_URL/api/jobs/$JOB_ID/result" -o "$RESULT_PATH"
    
    SIZE=$(ls -lh "$RESULT_PATH" | awk '{print $5}')
    echo "Result saved: $RESULT_PATH ($SIZE)"
    
    # Get dimensions
    DIMS=$(sips -g pixelWidth -g pixelHeight "$RESULT_PATH" 2>/dev/null | grep pixel)
    echo "$DIMS"
    
    break
  elif [ "$STATE" = "failed" ]; then
    echo "❌ Processing failed: $MESSAGE"
    exit 1
  fi
done

echo ""
echo "To view: open $RESULT_PATH"
