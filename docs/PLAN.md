# HeyFoS — Kế hoạch triển khai chi tiết (Implementation Plan)

**Ngày tạo:** 25 tháng 1, 2026  
**Mục tiêu:** Xây dựng ứng dụng focus stacking chất lượng cạnh tranh với Zerene Stacker/Helicon Focus, tối ưu cho Mac mini M2 24GB RAM, sử dụng Swift/Metal native.

---

## I. ĐÁNH GIÁ TỔNG QUAN (Executive Assessment)

### 1. Khả thi (Feasibility): ✅ Có

**Hardware:**
- Mac mini M2 (8-core CPU, 10-core GPU, 24GB Unified Memory) — đủ mạnh
- M2 GPU có Metal Performance Shaders (MPS) tối ưu cho parallel image processing
- 24GB RAM đủ xử lý stacks 20-50MP (với tiling cho ảnh lớn hơn)

**Software:**
- Swift 5.9+ và Metal 3 hỗ trợ đầy đủ trên macOS Sonoma/Sequoia
- LibRaw có binding Swift hoặc có thể wrap C++ library
- Vapor framework ổn định cho web backend

**Kết luận:** Dự án hoàn toàn khả thi với kiến trúc Swift/Metal native.

---

### 2. Các thay đổi kiến trúc quan trọng

#### Từ Python sang Swift/Metal — Lý do:
1. **Hiệu năng:** Metal kernels tận dụng GPU M2 tốt hơn PyTorch MPS (ít overhead)
2. **Memory efficiency:** Swift quản lý memory tốt hơn Python cho large arrays
3. **Tích hợp macOS:** Native process, ít dependency, stable deployment
4. **Web app:** Backend chạy server-side, user không cần cài đặt gì

#### Kiến trúc đề xuất: Hybrid với Vapor backend

```
┌─────────────────────────────────────────────────────────┐
│  User Browser (React/Vue hoặc Streamlit)                │
│  - Upload ảnh                                            │
│  - Chọn tham số                                          │
│  - Preview & download                                    │
└─────────────────┬───────────────────────────────────────┘
                  │ HTTPS
                  ▼
┌─────────────────────────────────────────────────────────┐
│  Cloudflare Tunnel                                       │
│  (heyfos.truyenthong.edu.vn -> localhost:7070)        │
└─────────────────┬───────────────────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────────────────────┐
│  Vapor Swift Web Server (localhost:7071)                │
│  - REST API endpoints                                    │
│  - Job queue management                                  │
│  - Session & file handling                               │
└─────────────────┬───────────────────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────────────────────┐
│  HeyFoS Processing Engine (Swift + Metal)             │
│                                                           │
│  ┌─────────────────────────────────────────────────┐   │
│  │ 1. RAW Decoder (LibRaw C++ wrapper)             │   │
│  │    - Swift Package wrapping libraw               │   │
│  │    - Convert RAW -> linear float32 RGB          │   │
│  └─────────────────────────────────────────────────┘   │
│                                                           │
│  ┌─────────────────────────────────────────────────┐   │
│  │ 2. Alignment Module (Metal/Accelerate)          │   │
│  │    - Feature detection (Metal compute shader)    │   │
│  │    - ECC/phase correlation (vImage/Accelerate)   │   │
│  │    - Sub-pixel warp (Metal texture sampling)     │   │
│  └─────────────────────────────────────────────────┘   │
│                                                           │
│  ┌─────────────────────────────────────────────────┐   │
│  │ 3. Focus Measure (Metal Compute Shaders)        │   │
│  │    - Laplacian/Tenengrad kernels                 │   │
│  │    - Multi-scale contrast map                    │   │
│  │    - Per-pixel/per-patch scoring                 │   │
│  └─────────────────────────────────────────────────┘   │
│                                                           │
│  ┌─────────────────────────────────────────────────┐   │
│  │ 4. Pyramid Fusion (Metal + MPS)                 │   │
│  │    - Gaussian pyramid (MPSImageGaussianPyramid) │   │
│  │    - Laplacian pyramid (custom Metal shader)     │   │
│  │    - Multi-band blending                         │   │
│  └─────────────────────────────────────────────────┘   │
│                                                           │
│  ┌─────────────────────────────────────────────────┐   │
│  │ 5. Deghosting (Optical Flow + Masking)          │   │
│  │    - Motion detection (Metal diff kernels)       │   │
│  │    - Optical flow (Metal Lucas-Kanade)           │   │
│  │    - Region masking & weighted blend             │   │
│  └─────────────────────────────────────────────────┘   │
│                                                           │
│  ┌─────────────────────────────────────────────────┐   │
│  │ 6. Post-process & Export                         │   │
│  │    - Color correction (Metal LUT)                │   │
│  │    - TIFF 16-bit export (vImage/CoreImage)       │   │
│  └─────────────────────────────────────────────────┘   │
│                                                           │
└───────────────────────────────────────────────────────────┘
                  │
                  ▼
          NVMe Storage (temp files & output)
```

---

### 3. Tối ưu hóa quan trọng (Critical Optimizations)

#### A. Memory Management
- **Tiling:** Chia ảnh >50MP thành tiles 2048×2048 với overlap 256px
- **Streaming:** Xử lý từng frame một, không load toàn bộ stack vào RAM
- **Metal Resource Pools:** Reuse MTLBuffer/MTLTexture để giảm allocation overhead

#### B. GPU Utilization
- **Metal Compute Shaders:** Convolution, Laplacian, focus measure, blending
- **MPS Operations:** Gaussian pyramid, matrix operations
- **Command Buffer Parallelism:** Batch operations, minimize CPU-GPU sync

#### C. Algorithm Quality
- **Multi-scale focus measure:** Combine Laplacian + Tenengrad + local contrast
- **Advanced pyramid blending:** 5-level Laplacian pyramid với smooth weight maps
- **Deghosting:** Optical flow + patch-based consistency check

---

## II. ROADMAP CHI TIẾT (Detailed Roadmap)

### Phase 1: Foundation & Core Engine (4-6 tuần)

#### Week 1-2: Project Setup & RAW Processing
- [ ] **Task 1.1:** Tạo Swift Package Manager project
  - Structure: `Sources/HeyFoS/`, `Sources/MetalShaders/`, `Tests/`
  - Dependencies: Vapor, SwiftImage (nếu cần), ArgumentParser
  
- [ ] **Task 1.2:** Integrate LibRaw
  - Wrap libraw C++ API với Swift
  - Test đọc CR3, NEF, ARW -> linear RGB float32
  - Benchmark performance (thời gian đọc 1 file 24MP RAW)

- [ ] **Task 1.3:** Setup Metal Pipeline
  - Tạo `MTLDevice`, `MTLCommandQueue`, `MTLLibrary`
  - Load Metal shaders từ `.metal` files
  - Test basic compute shader (image invert)

**Deliverable:** Swift CLI tool đọc RAW và xuất TIFF 16-bit

---

#### Week 3-4: Alignment Module
- [ ] **Task 2.1:** Feature Detection (Metal)
  - Implement FAST corner detection (Metal compute shader)
  - Harris corner detection backup
  - Extract keypoints -> Swift array

- [ ] **Task 2.2:** Feature Matching
  - ORB descriptor (Metal shader) hoặc dùng Accelerate framework
  - Brute-force matching hoặc FLANN-like approximation
  - RANSAC để filter outliers

- [ ] **Task 2.3:** Transform Estimation
  - Similarity transform (scale + rotation + translation)
  - Sub-pixel refinement với ECC hoặc phase correlation
  - Apply warp với Metal texture sampling (bilinear/bicubic)

**Deliverable:** Alignment module align 2 frames với sub-pixel accuracy

---

#### Week 5-6: Focus Measure & Basic Fusion
- [ ] **Task 3.1:** Focus Measure Kernels (Metal)
  ```metal
  // Laplacian kernel
  kernel void laplacian_focus(texture2d<float, access::read> input,
                               texture2d<float, access::write> output,
                               uint2 gid [[thread_position_in_grid]]) {
      // Implement 3x3 Laplacian convolution
      // Output: focus score per pixel
  }
  ```
  - Tenengrad (Sobel magnitude squared)
  - Multi-scale local contrast (3 scales: 5x5, 9x9, 17x17)

- [ ] **Task 3.2:** Simple Max Fusion
  - For each pixel, select frame with highest focus score
  - Output: initial focus-stacked image

- [ ] **Task 3.3:** Test với sample stacks
  - Chuẩn bị 3-5 bộ ảnh test (macro, landscape)
  - So sánh kết quả với simple averaging

**Deliverable:** Basic focus stacking CLI tool (max fusion)

---

### Phase 2: Advanced Fusion & Quality (6-8 tuần)

#### Week 7-9: Pyramid Blending
- [ ] **Task 4.1:** Gaussian Pyramid
  - Sử dụng `MPSImageGaussianPyramid` hoặc custom Metal shader
  - Build 5-level pyramid cho mỗi frame
  - Test memory usage (profile với Instruments)

- [ ] **Task 4.2:** Laplacian Pyramid
  - Subtract consecutive Gaussian levels
  - Store in Metal texture arrays
  
- [ ] **Task 4.3:** Weight Map Construction
  - Focus measure -> smooth weight map (Gaussian blur weight)
  - Normalize weights across frames per pixel
  - Build weight pyramid

- [ ] **Task 4.4:** Multi-band Blending
  - Blend Laplacian levels với weighted sum
  - Reconstruct từ pyramid -> final image
  - Compare với max fusion (visual quality check)

**Deliverable:** Pyramid blending fusion (no halos)

---

#### Week 10-12: Deghosting
- [ ] **Task 5.1:** Motion Detection
  - Frame differencing (Metal shader)
  - Threshold -> motion mask
  
- [ ] **Task 5.2:** Optical Flow (Simplified Lucas-Kanade)
  - Metal implementation hoặc dùng CoreImage/Vision framework
  - Estimate local motion vectors
  
- [ ] **Task 5.3:** Region-based Blending
  - Detect inconsistent regions
  - Fallback to single-frame selection cho vùng có chuyển động
  - Blend boundary với feathering

**Deliverable:** Deghosting module reduces artifacts

---

#### Week 13-14: Post-processing & Export
- [ ] **Task 6.1:** Color Correction
  - Auto white balance adjustment
  - Local contrast enhancement (CLAHE equivalent)
  
- [ ] **Task 6.2:** Export Formats
  - TIFF 16-bit (via vImage)
  - JPEG 8-bit với embedded metadata
  - PNG lossless

**Deliverable:** Complete processing pipeline

---

### Phase 3: Web Backend & Production (4-6 tuần)

#### Week 15-17: Vapor Web Server
- [ ] **Task 7.1:** REST API Design
  ```swift
  // Upload endpoint
  POST /api/stacks/create
  Body: multipart/form-data (images)
  Response: { stackId: "uuid" }
  
  // Process endpoint
  POST /api/stacks/{id}/process
  Body: { algorithm: "pyramid", params: {...} }
  Response: { jobId: "uuid" }
  
  // Status endpoint
  GET /api/jobs/{id}/status
  Response: { status: "processing", progress: 45 }
  
  // Download endpoint
  GET /api/jobs/{id}/result
  Response: TIFF file
  ```

- [ ] **Task 7.2:** Job Queue
  - Background processing với Swift Concurrency (async/await)
  - Queue management (max 2 concurrent jobs để tránh OOM)
  - Progress tracking

- [ ] **Task 7.3:** File Management
  - Upload storage (`/tmp/heyfos/uploads/{sessionId}/`)
  - Processing workspace
  - Auto-cleanup sau 24h

**Deliverable:** Vapor API server

---

#### Week 18-19: Frontend (Simple UI)
- [ ] **Option A:** Streamlit (Python, quick)
  - Upload widget
  - Parameter sliders
  - Display result
  
- [ ] **Option B:** React/Vue (Better UX)
  - Drag-drop upload
  - Real-time progress bar
  - Image comparison slider

**Deliverable:** Functional web UI

---

#### Week 20: Deployment & Monitoring
- [ ] **Task 9.1:** Cloudflare Tunnel Setup
  ```bash
  cloudflared tunnel create heyfos
  cloudflared tunnel route dns heyfos heyfos.truyenthong.edu.vn
  # Config: localhost:7070 -> public domain
  ```

- [ ] **Task 9.2:** Process Management
  - LaunchDaemon plist để auto-start Vapor server
  - Logging với os_log
  - Monitoring (RAM, CPU, GPU usage)

- [ ] **Task 9.3:** Security
  - Rate limiting (max 5 uploads/hour per IP)
  - File size limits (max 500MB per stack)
  - Input validation

**Deliverable:** Production-ready deployment

---

## III. KIẾN TRÚC KỸ THUẬT CHI TIẾT

### A. Swift Package Structure

```
HeyFoS/
├── Package.swift
├── Sources/
│   ├── HeyFoSCore/           # Core processing engine
│   │   ├── RAW/
│   │   │   ├── LibRawWrapper.swift
│   │   │   └── RAWDecoder.swift
│   │   ├── Alignment/
│   │   │   ├── FeatureDetector.swift
│   │   │   ├── FeatureMatcher.swift
│   │   │   └── ImageWarper.swift
│   │   ├── Focus/
│   │   │   ├── FocusMeasure.swift
│   │   │   └── FocusMap.swift
│   │   ├── Fusion/
│   │   │   ├── PyramidBuilder.swift
│   │   │   ├── Blender.swift
│   │   │   └── Deghosting.swift
│   │   └── Export/
│   │       └── ImageExporter.swift
│   ├── MetalShaders/           # Metal compute shaders
│   │   ├── Shaders.metal
│   │   ├── FocusMeasure.metal
│   │   ├── Pyramid.metal
│   │   └── Blend.metal
│   ├── HeyFoSAPI/            # Vapor web server
│   │   ├── main.swift
│   │   ├── Controllers/
│   │   │   ├── StackController.swift
│   │   │   └── JobController.swift
│   │   ├── Models/
│   │   │   ├── Stack.swift
│   │   │   ├── Job.swift
│   │   │   └── ProcessParams.swift
│   │   └── Services/
│   │       ├── ProcessingService.swift
│   │       └── JobQueue.swift
│   └── HeyFoSCLI/            # Command-line tool
│       └── main.swift
├── Tests/
│   ├── HeyFoSCoreTests/
│   └── TestAssets/
│       └── sample_stacks/
├── Resources/
│   └── default.metallib
└── README.md
```

---

### B. Metal Shader Examples

#### 1. Laplacian Focus Measure
```metal
#include <metal_stdlib>
using namespace metal;

kernel void laplacian_focus_measure(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= input.get_width() || gid.y >= input.get_height()) return;
    
    // Laplacian kernel (3x3)
    float kernel[9] = {
        0, -1,  0,
       -1,  4, -1,
        0, -1,  0
    };
    
    float sum = 0.0;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            int2 pos = int2(gid) + int2(dx, dy);
            pos = clamp(pos, int2(0), int2(input.get_width()-1, input.get_height()-1));
            
            float pixel = input.read(uint2(pos)).r; // Grayscale
            sum += pixel * kernel[(dy+1)*3 + (dx+1)];
        }
    }
    
    output.write(float4(abs(sum)), gid);
}
```

#### 2. Pyramid Downscale
```metal
kernel void downsample_gaussian(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    // Gaussian 5x5 kernel (simplified)
    float weights[25] = {
        1, 4, 6, 4, 1,
        4,16,24,16, 4,
        6,24,36,24, 6,
        4,16,24,16, 4,
        1, 4, 6, 4, 1
    };
    float weight_sum = 256.0;
    
    float4 sum = float4(0.0);
    uint2 input_pos = gid * 2; // Downsample by 2x
    
    for (int dy = -2; dy <= 2; dy++) {
        for (int dx = -2; dx <= 2; dx++) {
            int2 pos = int2(input_pos) + int2(dx, dy);
            pos = clamp(pos, int2(0), int2(input.get_width()-1, input.get_height()-1));
            
            float4 pixel = input.read(uint2(pos));
            sum += pixel * weights[(dy+2)*5 + (dx+2)];
        }
    }
    
    output.write(sum / weight_sum, gid);
}
```

---

### C. Performance Targets

| Metric | Target | Notes |
|--------|--------|-------|
| RAW decode | <500ms | Per 24MP RAW file |
| Alignment | <2s | Per frame pair (24MP) |
| Focus measure | <300ms | Per frame (Metal GPU) |
| Pyramid blending | <3s | Full stack (10 frames, 24MP) |
| Total processing | <30s | 10-frame stack, 24MP each |
| Peak memory | <18GB | Leave 6GB for system |
| Concurrent jobs | 2 | Limited by memory |

---

## IV. BENCHMARKING & QUALITY ASSURANCE

### Test Dataset
Chuẩn bị các bộ ảnh:
1. **Macro insects:** 10-20 frames, focus step 0.5mm, RAW 24MP
2. **Landscape depth:** 5-10 frames, varying DOF, RAW 45MP
3. **Product photography:** 15 frames, controlled lighting, TIFF 16-bit
4. **Challenge cases:** Moving subjects, wind, breathing, reflections

### Quality Metrics
- **Visual:** A/B comparison với Zerene Stacker (PMax) và Helicon Focus
- **Quantitative:**
  - Edge sharpness: MTF50 measurement
  - Halo detection: Local gradient anomalies
  - Artifact count: Manual annotation
  - Processing time: Average over 10 runs

### Success Criteria
- ✅ No visible halos on 90% of test images
- ✅ Edge sharpness within 5% of Zerene PMax
- ✅ Processing time <60s for 20-frame 24MP stack
- ✅ Memory usage <20GB for largest test case

---

## V. DEPLOYMENT CHECKLIST

- [ ] **Code:**
  - [ ] All tests passing (unit + integration)
  - [ ] Profiling completed (Instruments: Time Profiler, Allocations, Metal)
  - [ ] Code reviewed + documented
  
- [ ] **Infrastructure:**
  - [ ] Cloudflare Tunnel configured and tested
  - [ ] LaunchDaemon plist installed
  - [ ] Logging và monitoring setup (os_log -> syslog aggregator)
  - [ ] Backup strategy (code + sample outputs)
  
- [ ] **Security:**
  - [ ] Rate limiting active
  - [ ] File upload size limits enforced
  - [ ] Input validation (file types, EXIF injection check)
  - [ ] HTTPS enforced via Cloudflare
  
- [ ] **Documentation:**
  - [ ] API documentation (OpenAPI/Swagger)
  - [ ] User guide (how to prepare images)
  - [ ] Troubleshooting guide

---

## VI. RỦI RO & MITIGATION (Risks & Mitigations)

| Risk | Impact | Probability | Mitigation |
|------|--------|-------------|------------|
| LibRaw integration khó | High | Medium | Fallback: dùng `dcraw` CLI wrapper |
| Metal shader bugs | High | Medium | Extensive unit tests, validation outputs |
| Memory overflow (large stacks) | High | Low | Tiling implementation + memory limits |
| Alignment fails (extreme breathing) | Medium | Medium | Manual alignment override trong UI |
| Deghosting không hoàn hảo | Medium | High | User manual masking tool |
| Performance không đạt target | Medium | Low | Profile + optimize hotspots, consider C++ rewrite cho critical paths |

---

## VII. KẾT LUẬN & NEXT STEPS

### Đánh giá cuối:
✅ **Dự án hoàn toàn khả thi** với Swift/Metal trên Mac mini M2  
✅ **Chất lượng cạnh tranh:** Có thể đạt với pyramid blending + deghosting đúng cách  
✅ **Timeline hợp lý:** 14-20 tuần cho production-ready version  

### Immediate Next Steps (Tuần tới):
1. **Setup project:** Tạo Swift Package với Vapor dependency
2. **Prototype RAW reader:** LibRaw wrapper + test với CR3/NEF
3. **First Metal shader:** Laplacian focus measure kernel
4. **Benchmark baseline:** Python prototype để so sánh performance

### Long-term:
- Sau MVP: thêm AI-based depth prediction (optional)
- Mobile app version (iOS/iPadOS với Metal)
- Cloud scaling (nếu demand cao)

---

**Prepared by:** GitHub Copilot (Claude Sonnet 4.5)  
**Date:** January 25, 2026  
**Status:** Ready for implementation
