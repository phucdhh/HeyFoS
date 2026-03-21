#!/bin/bash
# HeyFoS - Build Script (Apple Silicon Release)
# Compiles optimised binaries for arm64 and places them in .build/release/

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "🔨 Building HeyFoS for Apple Silicon (release)..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Require Homebrew libraw
if ! brew list libraw &>/dev/null; then
    echo "📦 Installing libraw dependency..."
    brew install libraw
fi

# Release build — activates full -O2 optimisations + Metal shader compilation
swift build -c release \
    --arch arm64 \
    2>&1

echo ""
echo "✅ Build complete!"
echo "   Backend binary : .build/release/heyfos-server"
echo "   CLI binary     : .build/release/heyfos-cli"
echo ""
echo "Run './start.sh' to launch the application."
