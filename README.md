# HeyFoS

<div align="center">

**High-Performance Focus Stacking Engine for Apple Silicon**

[![Swift](https://img.shields.io/badge/Swift-5.9+-orange.svg)](https://swift.org)
[![Platform](https://img.shields.io/badge/Platform-macOS-lightgrey.svg)](https://www.apple.com/macos/)
[![Metal](https://img.shields.io/badge/Metal-3-blue.svg)](https://developer.apple.com/metal/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

[Features](#features) • [Demo](#demo) • [Installation](#installation) • [Usage](#usage) • [Architecture](#architecture) • [Contributing](#contributing)

</div>

---

## Overview

HeyFoS (Hey Focus Stacking) is a production-ready focus stacking application optimized for Apple Silicon (M1/M2/M3). It combines multiple images taken at different focus distances to create a single image with an extended depth of field, delivering quality comparable to commercial solutions like Zerene Stacker and Helicon Focus.

Built with **Swift** and **Metal**, HeyFoS leverages the full power of Apple Silicon GPUs for blazingly fast image processing while maintaining exceptional memory efficiency.

🌐 **Live Demo**: [https://heyfos.truyenthong.edu.vn](https://heyfos.truyenthong.edu.vn)

## Features

### 🚀 Performance
- **GPU-Accelerated**: Native Metal 3 compute shaders for maximum performance
- **Memory Efficient**: Optimized pipeline handles large image stacks (20-50+ MP)
- **Fast Processing**: 5-10× faster than Python-based solutions

### 📸 Image Support
- **RAW Formats**: CR2, CR3, NEF, ARW, and more via LibRaw
- **Standard Formats**: TIFF (16-bit), PNG, JPEG
- **High Quality**: Preserves 16-bit linear data throughout pipeline

### 🎯 Advanced Algorithms
- **Focus Measure**: Laplacian, Tenengrad, multi-scale contrast
- **Blending**: Pyramid blending (Laplacian/Gaussian), linear blending
- **Alignment**: Feature-based alignment with sub-pixel accuracy
- **Deghosting**: Motion detection and artifact removal

### 🌐 Web Interface
- **Modern UI**: Drag-and-drop file upload, real-time progress tracking
- **REST API**: Built with Vapor 4, full async/await support
- **Cloud Ready**: Cloudflare Tunnel integration for remote access

## Demo

![HeyFoS in Action](https://via.placeholder.com/800x400?text=HeyFoS+Focus+Stacking+Demo)

## Installation

### Prerequisites

- macOS 14+ (Sonoma or Sequoia)
- Xcode 15+ with Swift 5.9+
- Apple Silicon Mac (M1/M2/M3 recommended)
- Node.js 16+ (for frontend development)
- Homebrew

### Quick Start

```bash
# Clone the repository
git clone https://github.com/phucdhh/HeyFoS.git
cd HeyFoS

# Install dependencies
brew install libraw

# Build the project
swift build

# Run the server
swift run heyfos-api
```

The server will start at `http://localhost:7070`

### Frontend Setup

```bash
cd frontend
npm install
npm start
```

The frontend will be available at `http://localhost:7071`

## Usage

### Web Interface

1. Open your browser and navigate to `http://localhost:7071` (local) or `https://heyfos.truyenthong.edu.vn` (production)
2. Upload your image stack (RAW, TIFF, or JPEG files)
3. Configure processing parameters:
   - **Depth Map Algorithm**: Laplacian (default) or Tenengrad
   - **Blending Algorithm**: Pyramid (recommended) or Linear
   - **Pyramid Levels**: 3-10 (default: 7)
   - **Blur Radius**: 0.1-5.0 (default: 1.0)
4. Click "Start Processing" and monitor progress
5. Download the result when complete

### API Endpoints

```bash
# Upload images
POST /api/process/upload

# Start processing
POST /api/process/start

# Check status
GET /api/process/status/{sessionId}

# Download result
GET /api/process/download/{sessionId}
```

### CLI (Coming Soon)

```bash
# Process a stack of images
swift run heyfos-cli \
  --input ./images/*.CR2 \
  --output result.tiff \
  --algorithm pyramid \
  --levels 7
```

## Architecture

### Tech Stack

**Backend:**
- **Swift 5.9+** - Native performance, excellent memory management
- **Vapor 4** - Modern async web framework
- **Metal 3** - GPU-accelerated compute shaders
- **Accelerate** - vImage, vDSP for CPU-optimized operations
- **LibRaw** - Professional RAW file decoding

**Frontend:**
- **React 18** - Modern UI framework
- **Axios** - HTTP client for API communication
- **Material-UI** - Component library

**Infrastructure:**
- **Cloudflare Tunnel** - Secure remote access
- **Swift Concurrency** - Background job processing

### Processing Pipeline

```
Input Images (RAW/TIFF/JPEG)
    ↓
RAW Decoding (LibRaw) → Linear RGB 16-bit
    ↓
Alignment (Feature-based + ECC)
    ↓
Focus Measure Computation (Metal shaders)
    ↓
Pyramid Construction (Gaussian/Laplacian)
    ↓
Multi-scale Blending (Metal compute)
    ↓
Post-processing & Export (TIFF 16-bit)
```

### Project Structure

```
HeyFoS/
├── Sources/
│   ├── HeyFoSAPI/          # Vapor web server
│   ├── HeyFoSCLI/          # Command-line interface
│   ├── HeyFoSCore/         # Core processing engine
│   │   ├── Processing/     # Image processing algorithms
│   │   ├── Metal/          # Metal shaders and context
│   │   └── RAW/            # RAW file handling
│   └── CLibRaw/            # LibRaw C++ wrapper
├── frontend/               # React web interface
├── Tests/                  # Unit and integration tests
└── docs/                   # Documentation
```

## Performance

Benchmarked on Mac mini M2 (24GB RAM):

| Stack Size | Images | Resolution | Processing Time |
|------------|--------|------------|-----------------|
| Small      | 10     | 12 MP      | ~5 seconds      |
| Medium     | 20     | 24 MP      | ~15 seconds     |
| Large      | 30     | 50 MP      | ~45 seconds     |

*Times include RAW decoding, alignment, and pyramid blending*

## Documentation

- [Build Guide](docs/BUILD.md) - Detailed build instructions
- [Deployment](docs/DEPLOYMENT.md) - Production deployment guide
- [API Reference](docs/Methods.md) - Complete API documentation
- [Architecture](docs/PLAN.md) - Technical architecture details
- [Progress](docs/PROGRESS.md) - Development progress and milestones

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

### Development Setup

```bash
# Run tests
swift test

# Build in release mode
swift build -c release

# Format code
swift-format -i -r Sources/ Tests/
```

## Roadmap

- [x] RAW file decoding (LibRaw)
- [x] Metal compute pipeline
- [x] Focus measure algorithms (Laplacian, Tenengrad)
- [x] Pyramid blending
- [x] Web API (Vapor)
- [x] React frontend
- [x] Cloudflare Tunnel deployment
- [ ] Advanced deghosting
- [ ] CLI tool
- [ ] Batch processing
- [ ] Docker containerization

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- [LibRaw](https://www.libraw.org/) - RAW image decoder
- [Vapor](https://vapor.codes/) - Swift web framework
- Apple Metal and Accelerate frameworks

## Contact

- **Author**: Phuc Nguyen-Dang
- **GitHub**: [@phucdhh](https://github.com/phucdhh)
- **Project Link**: [https://github.com/phucdhh/HeyFoS](https://github.com/phucdhh/HeyFoS)

---

<div align="center">
Made with ❤️ and Swift on Apple Silicon
</div>
