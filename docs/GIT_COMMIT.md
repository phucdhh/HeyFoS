# Git Commit Guide

Nếu bạn muốn commit code này vào Git:

```bash
cd /Users/mac/HeyFoS

# Initialize git (nếu chưa có)
git init

# Add all files
git add .

# Commit
git commit -m "feat: Swift/Metal foundation - Metal shaders, CLI tool, Vapor server scaffold

- Package.swift with Vapor 4 and ArgumentParser dependencies
- Metal compute shaders: Laplacian, Tenengrad, Gaussian downsample, blending
- MetalContext: GPU device manager with runtime shader compilation
- CLI tool with verbose logging and Metal initialization
- Vapor web server stub with async/await support
- LibRaw wrapper interface (pending C++ integration)
- FocusMeasure processor stub
- Complete project documentation (PLAN.md, BUILD.md, SETUP_COMPLETE.md)

Build: ✅ Success
Tests: Metal shaders load correctly on Apple M2
Status: Foundation complete, ready for LibRaw integration

See PLAN.md for 20-week roadmap."
```

## Next Git Steps

```bash
# Create GitHub repo and push
git remote add origin https://github.com/yourusername/HeyFoS.git
git branch -M main
git push -u origin main
```

## Recommended .gitattributes

```
*.metal linguist-language=Metal
*.swift linguist-language=Swift
```
