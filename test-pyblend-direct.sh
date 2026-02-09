#!/bin/bash

# Test HeyFoS PyBlend optimization directly with CLI
echo "=== Testing Optimized PyBlend with TIFF samples ==="

# Create test session directories
USER_ID="test-$(date +%s)"
SESSION_ID="session-$(date +%s)"
UPLOAD_DIR="./users/$USER_ID/$SESSION_ID/upload"
RESULT_DIR="./users/$USER_ID/$SESSION_ID/result"

mkdir -p "$UPLOAD_DIR"
mkdir -p "$RESULT_DIR"

# Copy TIFF files to upload directory
echo ""
echo "Copying 19 TIFF files (12MP each)..."
cp tiff-samples/*.TIF "$UPLOAD_DIR/"
FILE_COUNT=$(ls -1 "$UPLOAD_DIR"/*.TIF 2>/dev/null | wc -l | tr -d ' ')
echo "✓ $FILE_COUNT files copied to $UPLOAD_DIR"

# Output path
OUTPUT_PATH="$RESULT_DIR/result.tiff"
echo ""
echo "Output will be saved to: $OUTPUT_PATH"

# Run CLI directly
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🚀 Starting PyBlend processing..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
START_TIME=$(date +%s)

# Build and run
swift run heyfos-cli \
  --input "$UPLOAD_DIR" \
  --output "$OUTPUT_PATH" \
  --method laplacian \
  --pyramid-blending \
  --verbose

EXIT_CODE=$?
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ $EXIT_CODE -eq 0 ]; then
  echo "✅ Processing completed in ${ELAPSED}s"
  echo ""
  echo "📊 Result file info:"
  if [ -f "$OUTPUT_PATH" ]; then
    FILE_SIZE=$(ls -lh "$OUTPUT_PATH" | awk '{print $5}')
    echo "   Size: $FILE_SIZE"
    echo "   Path: $OUTPUT_PATH"
    echo ""
    echo "📐 Image properties:"
    sips -g all "$OUTPUT_PATH" | grep -E "(pixelWidth|pixelHeight|format|fileSize|samplesPerPixel|bitsPerSample)"
    echo ""
    echo "💡 View the result:"
    echo "   open $OUTPUT_PATH"
  else
    echo "❌ Result file not found!"
  fi
else
  echo "❌ Processing failed with exit code $EXIT_CODE"
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
