#!/bin/bash

# Test HeyFoS với TIFF samples dataset
# Output: 10MP optimized

echo "=== Testing HeyFoS with TIFF samples ==="
echo "Input: 19 x 12MP TIFF files (4256x2832)"
echo "Output: 10MP (max 3840px)"
echo ""

# Generate unique IDs
USER_ID="test-user-$(date +%s)"
SESSION_ID="test-session-$(date +%s)"

# Create directory structure
UPLOAD_DIR="/Users/mac/HeyFoS/users/$USER_ID/$SESSION_ID/upload"
mkdir -p "$UPLOAD_DIR"

echo "Copying TIFF files to upload directory..."
cp /Users/mac/HeyFoS/tiff-samples/*.TIF "$UPLOAD_DIR/"
FILE_COUNT=$(ls -1 "$UPLOAD_DIR"/*.TIF | wc -l)
echo "✓ Copied $FILE_COUNT files"

echo ""
echo "Starting HeyFoS processing..."
echo "User ID: $USER_ID"
echo "Session ID: $SESSION_ID"
echo ""

# Run processing via Swift directly
cd /Users/mac/HeyFoS

# Create simple test Swift script
cat > /tmp/test_process.swift << 'EOF'
import Foundation
import HeyFoSCore

print("Initializing Metal context...")
let context = try! MetalContext()
let processor = StackProcessor(metalContext: context)

let inputDir = URL(fileURLWithPath: CommandLine.arguments[1])
let outputPath = CommandLine.arguments[2]

print("Processing stack from: \(inputDir.path)")
print("Output to: \(outputPath)")

let startTime = Date()

try! processor.processStack(
    inputDirectory: inputDir,
    outputPath: outputPath,
    method: .laplacian,
    useAlignment: false,
    usePyramidBlending: true,
    verbose: false
)

let elapsed = Date().timeIntervalSince(startTime)
print("")
print("=== COMPLETED ===")
print("Time: \(String(format: "%.1f", elapsed))s")
print("Output: \(outputPath)")

// Check output file size
if let attrs = try? FileManager.default.attributesOfItem(atPath: outputPath),
   let size = attrs[.size] as? Int64 {
    let sizeMB = Double(size) / 1024 / 1024
    print("Size: \(String(format: "%.1f", sizeMB))MB")
}
EOF

# Compile and run
OUTPUT_PATH="$UPLOAD_DIR/../result.tiff"
echo "Compiling test..."
swift /tmp/test_process.swift "$UPLOAD_DIR" "$OUTPUT_PATH" 2>&1

echo ""
echo "=== Test complete ==="
echo "Result: $OUTPUT_PATH"
echo ""
echo "To view result:"
echo "  open $OUTPUT_PATH"
