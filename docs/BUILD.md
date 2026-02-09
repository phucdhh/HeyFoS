# HeyFoS — Swift/Metal Build & Test Guide

Quick start guide for building and testing the HeyFoS Swift project.

## Prerequisites

- macOS 14+ (Sonoma or Sequoia)
- Xcode 15+ (includes Swift 5.9 and Metal 3)
- Homebrew (for dependencies)

## Installation

### 1. Install LibRaw (for RAW decoding)

```bash
brew install libraw
```

### 2. Clone and Build

```bash
cd /Users/mac/HeyFoS

# Resolve dependencies
swift package resolve

# Build the project
swift build

# Build in release mode (optimized)
swift build -c release
```

## Running

### CLI Tool

```bash
# Debug build
swift run heyfos-cli --input ./test_data/stack1 --output ./output.tiff

# Release build (faster)
swift run -c release heyfos-cli --input ./test_data/stack1 --output ./output.tiff --verbose
```

### Web Server

```bash
# Start Vapor server
swift run heyfos-server

# Server runs on http://localhost:7070
# Visit http://localhost:7070/health to check status
```

## Testing

```bash
# Run all tests
swift test

# Run specific test
swift test --filter MetalTests

# Run with verbose output
swift test --verbose
```

## Development

### Generate Xcode Project (Optional)

```bash
swift package generate-xcodeproj
open HeyFoS.xcodeproj
```

Or use VS Code with Swift extensions.

### Project Structure

```
HeyFoS/
├── Package.swift                    # SPM manifest
├── Sources/
│   ├── HeyFoSCore/               # Core processing library
│   │   ├── Metal/
│   │   │   ├── Shaders.metal       # Metal compute shaders
│   │   │   └── MetalContext.swift  # Metal device manager
│   │   ├── RAW/
│   │   │   └── LibRawWrapper.swift # RAW decoder (stub)
│   │   └── Processing/
│   │       └── FocusMeasure.swift  # Focus quality processor
│   ├── HeyFoSCLI/                # Command-line tool
│   │   └── main.swift
│   └── HeyFoSAPI/                # Vapor web server
│       └── main.swift
└── Tests/
    └── HeyFoSCoreTests/
        └── MetalTests.swift
```

## Next Steps

Current status: **Foundation scaffold complete** ✅

To continue implementation, see [PLAN.md](PLAN.md) for detailed roadmap.

**Immediate next tasks:**
1. ✅ Project structure & Metal shaders created
2. ⬜ Integrate LibRaw C++ library (bridging header + linking)
3. ⬜ Implement image loading & Metal texture conversion
4. ⬜ Test focus measure with sample images
5. ⬜ Implement alignment module
6. ⬜ Implement pyramid blending

## Troubleshooting

### Metal device not found
Ensure you're running on Apple Silicon Mac. Intel Macs need different Metal setup.

### LibRaw linking errors
```bash
# Check if LibRaw is installed
brew info libraw

# Reinstall if needed
brew reinstall libraw
```

### Swift package resolution fails
```bash
# Clear package cache
swift package reset

# Update dependencies
swift package update
```

## Performance Notes

- Debug builds are ~10× slower than release builds
- Use `swift build -c release` for performance testing
- Profile with Xcode Instruments (Time Profiler, Metal System Trace)

## License

Proprietary / Internal Use for Truyenthong.edu.vn
