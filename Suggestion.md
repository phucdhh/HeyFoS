# HeyFoS Improvement Suggestions

> **Document purpose:** Technical roadmap for improving focus stacking quality in HeyFoS to match and surpass Helicon Focus / Zerene Stacker.  
> **Based on:** Visual artifact analysis from comparison image (31-image stack of gastropod shell), codebase review (Swift 5.9 + Metal 3 + Accelerate).  
> **Priority legend:** 🔴 Critical (do first) · 🟡 Important · 🟢 Enhancement

---

## Table of Contents

1. [Artifact Diagnosis from Comparison Image](#1-artifact-diagnosis-from-comparison-image)
2. [Quick Wins — No New Code Required](#2-quick-wins--no-new-code-required)
3. [Fix 1 — Specular Suppression in Focus Measure](#3-fix-1--specular-suppression-in-focus-measure)
4. [Fix 2 — Guided Filter for Weight Map Smoothing](#4-fix-2--guided-filter-for-weight-map-smoothing)
5. [Fix 3 — Ensemble Focus Measure](#5-fix-3--ensemble-focus-measure)
6. [Fix 4 — Color Consistency Before Blending](#6-fix-4--color-consistency-before-blending)
7. [Fix 5 — Sub-pixel Depth via Parabolic Interpolation](#7-fix-5--sub-pixel-depth-via-parabolic-interpolation)
8. [Advanced — Alignment Improvements](#8-advanced--alignment-improvements)
9. [Advanced — Neural Blending Path](#9-advanced--neural-blending-path)
10. [Testing & Validation Framework](#10-testing--validation-framework)
11. [Implementation Timeline](#11-implementation-timeline)

---

## 1. Artifact Diagnosis from Comparison Image

Phân tích ảnh so sánh (HeyFoS bên phải, Helicon Focus bên trái) cho thấy 3 vấn đề riêng biệt:

### Artifact A — Halo trắng tại miệng lỗ tròn (🔴 Nghiêm trọng nhất)

**Biểu hiện:** Viền sáng dày ~10–20px bao quanh phần miệng vỏ ốc (vùng hình tròn ở đỉnh ảnh). Helicon không có artifact này.

**Nguyên nhân gốc rễ:**  
Miệng lỗ tròn là `specular rim` — vùng có contrast cực cao giữa vành sáng và bóng tối bên trong. Laplacian variance tại đây cho điểm rất cao không phải vì ảnh sắc nét mà vì là **specular edge**. Pyramid blending sau đó nhân artifact này lên ở nhiều band tần số.

**File liên quan:** `FocusMeasure.metal`, `PyramidBlender.swift`

---

### Artifact B — Edge ringing dọc vân xoắn (🟡 Quan trọng)

**Biểu hiện:** Dải sáng/tối xen kẽ (Gibbs-like ringing) dọc theo cạnh các vân xoắn của ốc, đặc biệt rõ ở vùng giữa ảnh.

**Nguyên nhân gốc rễ:**  
`blurRadius` mặc định 1.0 tạo weight mask quá cứng (hard transition). Khi pyramid blend, các band tần số cao tại vùng edge nhận weight thay đổi đột ngột → ringing. Đây là hiện tượng tương tự Gibbs phenomenon trong xử lý tín hiệu.

**File liên quan:** `PyramidBlender.swift`, config `blurRadius`

---

### Artifact C — Lệch màu tổng thể (🟢 Enhancement)

**Biểu hiện:** Ảnh HeyFoS hơi trắng/lạnh hơn Helicon. Không phải lỗi thuật toán blending mà là thiếu bước normalize exposure/color giữa các frame.

**Nguyên nhân gốc rễ:**  
Focus breathing (lens thay đổi focal length nhẹ khi focus), vignetting, và sự thay đổi nhỏ về exposure giữa các frame RAW → mỗi frame có color profile hơi khác nhau. Blend trực tiếp mà không normalize → màu kết quả là trung bình không nhất quán.

**File liên quan:** `RAWProcessor.swift`, bước preprocessing trước blend

---

## 2. Quick Wins — No New Code Required

Thử ngay các thay đổi tham số này với ảnh ốc sên trước khi viết code mới. Nếu kết quả cải thiện rõ → xác nhận đúng nguyên nhân.

```json
// API request thử nghiệm
{
  "depthMapAlgorithm": "tenengrad",
  "blendingAlgorithm": "pyramid",
  "pyramidLevels": 4,
  "blurRadius": 2.8
}
```

| Tham số | Giá trị hiện tại | Giá trị thử | Lý do |
|---|---|---|---|
| `depthMapAlgorithm` | `laplacian` | `tenengrad` | Tenengrad ít nhạy cảm hơn với noise so với Laplacian variance |
| `pyramidLevels` | `7` | `4–5` | Ít level → giảm artifact tích lũy qua nhiều band |
| `blurRadius` | `1.0` | `2.5–3.0` | Weight mask mượt hơn → giảm ringing tại edge |

> **Kỳ vọng:** Halo và ringing giảm 30–50% chỉ bằng tuning tham số. Đây là baseline để đo cải tiến của các fix tiếp theo.

---

## 3. Fix 1 — Specular Suppression in Focus Measure

**Priority:** 🔴 Critical  
**Effort:** 1–2 ngày  
**Expected improvement:** Loại bỏ 80–90% halo artifact

### Nguyên lý

Thêm `specular mask` vào pipeline tính focus score. Vùng luminance > ngưỡng (threshold) được giảm weight xuống — nhưng không xóa hoàn toàn để không tạo "lỗ hổng" trong depth map.

### Implementation trong Metal

**File:** `Sources/HeyFoSCore/Metal/FocusMeasure.metal`

```metal
// Thêm hàm helper specular detection
float computeSpecularWeight(float4 pixel, float threshold, float softness) {
    // Tính luminance theo chuẩn Rec. 709
    float luminance = dot(pixel.rgb, float3(0.2126, 0.7152, 0.0722));
    
    // smoothstep: soft transition thay vì hard cutoff
    // Giá trị trong khoảng [threshold - softness, threshold + softness]
    // được giảm dần thay vì cắt đứt
    float specularFactor = smoothstep(threshold - softness, threshold + softness, luminance);
    
    // Trả về weight: 1.0 ở vùng bình thường, tiến về 0.15 ở vùng specular
    // Không về 0 để tránh artifact "lỗ hổng" trong depth map
    return 1.0 - specularFactor * 0.85;
}

// Kernel chính — sửa lại hàm focus measure hiện tại
kernel void computeFocusMap(
    texture2d<float, access::read>  inputTexture   [[texture(0)]],
    texture2d<float, access::write> outputTexture  [[texture(1)]],
    constant FocusParams&           params         [[buffer(0)]],
    uint2                           gid            [[thread_position_in_grid]])
{
    uint2 textureSize = uint2(inputTexture.get_width(), inputTexture.get_height());
    if (gid.x >= textureSize.x || gid.y >= textureSize.y) return;
    
    float4 pixel = inputTexture.read(gid);
    
    // === CODE HIỆN TẠI: tính Laplacian/Tenengrad score ===
    // (giữ nguyên phần này)
    float rawFocusScore = computeLaplacianVariance(inputTexture, gid);
    // hoặc: float rawFocusScore = computeTenengrad(inputTexture, gid);
    
    // === THÊM MỚI: specular suppression ===
    float specularWeight = computeSpecularWeight(
        pixel,
        params.specularThreshold,  // default: 0.92
        params.specularSoftness    // default: 0.06
    );
    
    float finalScore = rawFocusScore * specularWeight;
    
    outputTexture.write(float4(finalScore, 0, 0, 1), gid);
}
```

**File:** `Sources/HeyFoSCore/Processing/FocusParams.swift`

```swift
// Thêm vào struct FocusParams (hoặc tạo mới nếu chưa có)
struct FocusParams {
    var algorithm: FocusMeasureAlgorithm = .laplacian
    var pyramidLevels: Int = 6
    var blurRadius: Float = 2.5
    
    // Thêm mới
    var specularThreshold: Float = 0.92   // luminance ngưỡng detect specular
    var specularSoftness: Float = 0.06    // transition width (soft edge)
    var enableSpecularSuppression: Bool = true
}
```

**File:** `Sources/HeyFoSAPI/Routes/ProcessRoutes.swift`

```swift
// Expose tham số mới qua API để frontend có thể điều chỉnh
struct ProcessRequest: Content {
    var depthMapAlgorithm: String = "laplacian"
    var blendingAlgorithm: String = "pyramid"
    var pyramidLevels: Int = 6
    var blurRadius: Float = 2.5
    
    // Thêm mới
    var specularThreshold: Float = 0.92
    var enableSpecularSuppression: Bool = true
}
```

### Calibration guide

Specular threshold phụ thuộc vào chất liệu chụp:

| Chủ thể | specularThreshold | specularSoftness |
|---|---|---|
| Vỏ ốc, vật thể bóng | 0.90 | 0.06 |
| Côn trùng (mắt bóng) | 0.88 | 0.08 |
| Bề mặt mờ (hoa, lông) | 0.96 | 0.03 |
| Kính, kim loại | 0.85 | 0.10 |

> **Gợi ý UX:** Thêm preset dropdown "Subject type" trong frontend thay vì để user nhập số thủ công.

---

## 4. Fix 2 — Guided Filter for Weight Map Smoothing

**Priority:** 🟡 Important  
**Effort:** 3–5 ngày  
**Expected improvement:** Loại bỏ ringing, giữ edge vật thể sắc nét trong khi smooth transition weight

### Tại sao Guided Filter tốt hơn Gaussian

Gaussian blur làm mờ **đều** mọi hướng → weight transition tại edge vật thể bị mờ → ringing.

Guided filter blur **theo cấu trúc ảnh** → weight transition mượt trong vùng flat, **giữ nguyên** tại edge thực sự của vật thể.

```
Gaussian:  [──────⟶ blur ──────]  → edge bị mờ
Guided:    [──── blur ────|edge]  → edge sắc, vùng flat mượt
```

### Implementation sử dụng vImage (Accelerate framework — không cần thư viện ngoài)

**File:** `Sources/HeyFoSCore/Processing/GuidedFilter.swift`

```swift
import Accelerate

/// Edge-preserving guided filter for weight map smoothing.
/// Reference: He et al. (2013) "Guided Image Filtering", IEEE TPAMI
struct GuidedFilter {
    let radius: Int      // local window radius (default: 8)
    let epsilon: Float   // regularization (default: 0.01 * 0.01)
    
    init(radius: Int = 8, epsilon: Float = 1e-4) {
        self.radius = radius
        self.epsilon = epsilon
    }
    
    /// - Parameters:
    ///   - guide: Guidance image (grayscale float32, normalized 0–1)
    ///   - input: Input weight map to be filtered (float32, same size as guide)
    ///   - width: Image width
    ///   - height: Image height
    /// - Returns: Filtered weight map, same dimensions
    func filter(guide: [Float], input: [Float], width: Int, height: Int) -> [Float] {
        let n = width * height
        
        // Step 1: Compute local means using box filter (vDSP)
        var meanI  = boxFilter(guide, width: width, height: height, radius: radius)
        var meanP  = boxFilter(input, width: width, height: height, radius: radius)
        var meanIP = boxFilter(multiplyElementwise(guide, input, count: n),
                               width: width, height: height, radius: radius)
        var meanII = boxFilter(multiplyElementwise(guide, guide, count: n),
                               width: width, height: height, radius: radius)
        
        // Step 2: Compute covariance and variance
        // covIP = mean(I*P) - mean(I)*mean(P)
        var covIP = [Float](repeating: 0, count: n)
        vDSP_vsub(multiplyElementwise(meanI, meanP, count: n), 1,
                  meanIP, 1, &covIP, 1, vDSP_Length(n))
        
        // varI = mean(I*I) - mean(I)*mean(I)
        var varI = [Float](repeating: 0, count: n)
        vDSP_vsub(multiplyElementwise(meanI, meanI, count: n), 1,
                  meanII, 1, &varI, 1, vDSP_Length(n))
        
        // Step 3: Compute linear coefficients
        // a = covIP / (varI + epsilon)
        var a = [Float](repeating: 0, count: n)
        var eps = epsilon
        vDSP_vsadd(varI, 1, &eps, &a, 1, vDSP_Length(n))
        vDSP_vdiv(a, 1, covIP, 1, &a, 1, vDSP_Length(n))
        
        // b = mean(P) - a * mean(I)
        var b = [Float](repeating: 0, count: n)
        vDSP_vmul(a, 1, meanI, 1, &b, 1, vDSP_Length(n))
        vDSP_vsub(b, 1, meanP, 1, &b, 1, vDSP_Length(n))
        
        // Step 4: Smooth a and b
        let meanA = boxFilter(a, width: width, height: height, radius: radius)
        let meanB = boxFilter(b, width: width, height: height, radius: radius)
        
        // Step 5: Compute output: q = mean(a) * I + mean(b)
        var output = [Float](repeating: 0, count: n)
        vDSP_vmul(meanA, 1, guide, 1, &output, 1, vDSP_Length(n))
        vDSP_vadd(output, 1, meanB, 1, &output, 1, vDSP_Length(n))
        
        return output
    }
    
    // MARK: - Private helpers
    
    private func boxFilter(_ src: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        // Sử dụng vImage_Buffer để tận dụng hardware-accelerated box filter
        var srcBuffer = vImage_Buffer()
        var dstBuffer = vImage_Buffer()
        
        var srcCopy = src
        srcCopy.withUnsafeMutableBufferPointer { ptr in
            srcBuffer = vImage_Buffer(
                data: ptr.baseAddress,
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: width * MemoryLayout<Float>.size
            )
        }
        
        var dst = [Float](repeating: 0, count: width * height)
        dst.withUnsafeMutableBufferPointer { ptr in
            dstBuffer = vImage_Buffer(
                data: ptr.baseAddress,
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: width * MemoryLayout<Float>.size
            )
        }
        
        // Horizontal pass
        vImageBoxConvolve_PlanarF(&srcBuffer, &dstBuffer, nil,
                                   0, 0, UInt32(radius * 2 + 1), 1,
                                   0, vImage_Flags(kvImageEdgeExtend))
        // Vertical pass
        vImageBoxConvolve_PlanarF(&dstBuffer, &srcBuffer, nil,
                                   0, 0, 1, UInt32(radius * 2 + 1),
                                   0, vImage_Flags(kvImageEdgeExtend))
        return srcCopy
    }
    
    private func multiplyElementwise(_ a: [Float], _ b: [Float], count: Int) -> [Float] {
        var result = [Float](repeating: 0, count: count)
        vDSP_vmul(a, 1, b, 1, &result, 1, vDSP_Length(count))
        return result
    }
}
```

### Tích hợp vào PyramidBlender

**File:** `Sources/HeyFoSCore/Processing/PyramidBlender.swift`

```swift
// Thêm vào class PyramidBlender

private let guidedFilter = GuidedFilter(radius: 8, epsilon: 1e-4)

// Trong hàm blendWeights() hoặc tương đương:
func smoothWeightMap(weights: [Float], guidance: [Float],
                     width: Int, height: Int) -> [Float] {
    // Thay thế Gaussian blur hiện tại bằng Guided filter
    return guidedFilter.filter(
        guide: guidance,   // dùng ảnh grayscale làm guidance
        input: weights,    // weight map cần smooth
        width: width,
        height: height
    )
}
```

---

## 5. Fix 3 — Ensemble Focus Measure

**Priority:** 🟡 Important  
**Effort:** 2–3 ngày  
**Expected improvement:** Depth map ổn định hơn, ít noise ở vùng texture phức tạp

### Nguyên lý

Không có metric đơn lẻ nào hoạt động tốt trên mọi loại texture. Ensemble (tổ hợp nhiều metric) triệt tiêu điểm yếu của từng cái:

| Metric | Mạnh ở | Yếu ở |
|---|---|---|
| Laplacian variance | Texture rõ ràng | Specular, noise |
| Tenengrad | Edge sắc | Vùng gradient đơn hướng |
| Local variance | Texture nhỏ | Vùng flat |
| GLVN (normalized) | Ổn định với exposure | Tính chậm hơn |

### Implementation

**File:** `Sources/HeyFoSCore/Metal/FocusMeasure.metal`

```metal
// Kernel mới: ensemble focus measure
kernel void computeEnsembleFocusMap(
    texture2d<float, access::read>  inputTexture  [[texture(0)]],
    texture2d<float, access::write> outputTexture [[texture(1)]],
    constant EnsembleParams&        params        [[buffer(0)]],
    uint2                           gid           [[thread_position_in_grid]])
{
    uint2 sz = uint2(inputTexture.get_width(), inputTexture.get_height());
    if (gid.x >= sz.x || gid.y >= sz.y) return;
    
    // Tính từng metric
    float scoreLaplacian  = computeLaplacianVariance(inputTexture, gid, params.windowSize);
    float scoreTenengrad  = computeTenengrad(inputTexture, gid);
    float scoreVariance   = computeLocalVariance(inputTexture, gid, params.windowSize);
    
    // Normalize riêng từng metric về [0, 1] trong một pass riêng (xem note bên dưới)
    // Ở đây dùng giá trị đã normalize từ pass trước
    float normLaplacian = scoreLaplacian * params.normScaleLaplacian;
    float normTenengrad = scoreTenengrad * params.normScaleTenengrad;
    float normVariance  = scoreVariance  * params.normScaleVariance;
    
    // Weighted ensemble
    float ensemble = params.weightLaplacian * normLaplacian
                   + params.weightTenengrad * normTenengrad
                   + params.weightVariance  * normVariance;
    
    // Specular suppression (từ Fix 1)
    float4 pixel = inputTexture.read(gid);
    float luminance = dot(pixel.rgb, float3(0.2126, 0.7152, 0.0722));
    float specWeight = 1.0 - smoothstep(0.88, 0.96, luminance) * 0.85;
    
    outputTexture.write(float4(ensemble * specWeight, 0, 0, 1), gid);
}
```

**File:** `Sources/HeyFoSCore/Processing/FocusMeasureEnsemble.swift`

```swift
struct EnsembleParams {
    // Weights — tổng phải bằng 1.0
    var weightLaplacian: Float = 0.45
    var weightTenengrad: Float = 0.35
    var weightVariance:  Float = 0.20
    
    var windowSize: Int = 5  // pixel window cho local statistics
    
    // Normalization scales — tính trong một pass riêng trên toàn stack
    var normScaleLaplacian: Float = 1.0
    var normScaleTenengrad: Float = 1.0
    var normScaleVariance:  Float = 1.0
}

// Trước khi blend, normalize scales dựa trên toàn stack
func computeNormalizationScales(focusMaps: [[Float]]) -> (Float, Float, Float) {
    // Tìm max value của mỗi metric qua toàn bộ frames
    // để normalize tất cả về cùng range [0, 1]
    let maxLap = focusMaps.flatMap { $0 }.max() ?? 1.0
    return (1.0 / max(maxLap, 1e-6), 1.0, 1.0)
}
```

> **Note về normalization:** Phải tính max value của mỗi metric qua toàn bộ frames trong stack TRƯỚC khi ensemble. Nếu không, metric có range lớn hơn sẽ dominate không đúng theo weight.

---

## 6. Fix 4 — Color Consistency Before Blending

**Priority:** 🟡 Important  
**Effort:** 2–3 ngày  
**Expected improvement:** Loại bỏ color cast, màu nhất quán với Helicon

### Nguyên nhân technical

Focus breathing → magnification thay đổi nhẹ giữa frames → khi align xong, pixel tương ứng từ hai frame khác nhau có exposure và color hơi khác → blend tạo ra màu "trung bình" không nhất quán.

### Implementation dùng Accelerate/vImage

**File:** `Sources/HeyFoSCore/Processing/ColorConsistency.swift`

```swift
import Accelerate

struct ColorConsistencyProcessor {
    
    /// Normalize tất cả frames trong stack về cùng color reference.
    /// Reference frame = frame giữa stack (thường là frame focus ở mid-distance).
    func normalizeStack(frames: inout [[Float]], width: Int, height: Int,
                        channels: Int = 3) {
        guard frames.count > 1 else { return }
        
        let referenceIndex = frames.count / 2
        let reference = frames[referenceIndex]
        
        // Tính mean và std của reference
        let (refMean, refStd) = computeMeanStd(reference, count: reference.count)
        
        for i in 0..<frames.count where i != referenceIndex {
            let (frameMean, frameStd) = computeMeanStd(frames[i], count: frames[i].count)
            
            // Reinhard-style color transfer: match mean và std
            // output = (input - frameMean) / frameStd * refStd + refMean
            let scale = refStd / max(frameStd, 1e-6)
            let bias  = refMean - frameMean * scale
            
            var result = [Float](repeating: 0, count: frames[i].count)
            let count  = vDSP_Length(frames[i].count)
            
            // result = frames[i] * scale + bias
            vDSP_vsmsa(frames[i], 1, [scale], [bias], &result, 1, count)
            
            // Clamp về [0, 1]
            var low:  Float = 0.0
            var high: Float = 1.0
            vDSP_vclip(result, 1, &low, &high, &result, 1, count)
            
            frames[i] = result
        }
    }
    
    // MARK: - Private
    
    private func computeMeanStd(_ data: [Float], count: Int) -> (mean: Float, std: Float) {
        var mean: Float = 0
        var std:  Float = 0
        vDSP_normalize(data, 1, nil, 1, &mean, &std,
                       vDSP_Length(count))
        return (mean, std)
    }
}
```

### Tích hợp vào pipeline

**File:** `Sources/HeyFoSCore/Processing/FocusStackingPipeline.swift`

```swift
// Thêm bước này VÀO SAU alignment, TRƯỚC khi tính focus measure

async func process(images: [CGImage]) async throws -> CGImage {
    // Bước 1: RAW decode → linear float
    var frames = try await decodeAll(images)
    
    // Bước 2: Alignment (giữ nguyên)
    frames = try await align(frames)
    
    // Bước 3: MỚI — Color consistency normalization
    let colorProcessor = ColorConsistencyProcessor()
    colorProcessor.normalizeStack(
        frames: &frames,
        width: outputWidth,
        height: outputHeight
    )
    
    // Bước 4: Focus measure (với specular suppression từ Fix 1)
    let focusMaps = try await computeEnsembleFocusMaps(frames)
    
    // Bước 5: Pyramid blending (với guided filter từ Fix 2)
    return try await pyramidBlend(frames, focusMaps: focusMaps)
}
```

---

## 7. Fix 5 — Sub-pixel Depth via Parabolic Interpolation

**Priority:** 🟢 Enhancement  
**Effort:** 1 ngày  
**Expected improvement:** Depth map smooth hơn, giảm "staircase artifact" tại vùng chuyển tiếp giữa hai frames liền kề

### Nguyên lý

Depth map thô = argmax của focus score theo frame index → chỉ có độ phân giải bằng số frames (discrete). Parabolic interpolation fit parabola qua 3 điểm score liền kề → tìm đỉnh thực ở vị trí sub-frame → depth resolution tăng 5–10x không cần chụp thêm ảnh.

```
Frame score:  [0.3, 0.7, 0.9, 0.6, 0.2]
Argmax = 2 (frame thứ 3)

Parabolic fit quanh đỉnh (frames 1,2,3):
Peak = 2 + (0.7 - 0.6) / (2 * (0.7 - 2*0.9 + 0.6)) = 2.1
→ Depth = frame 2.1 (sub-pixel position)
```

**File:** `Sources/HeyFoSCore/Processing/DepthMapProcessor.swift`

```swift
extension DepthMapProcessor {
    
    /// Refine depth map với sub-pixel accuracy via parabolic interpolation.
    /// Gọi hàm này sau khi tính argmax depth map thô.
    ///
    /// - Parameters:
    ///   - depthMap: Argmax depth map (float, value = frame index)
    ///   - focusStack: Mảng focus score maps [frameIndex][pixelIndex]
    ///   - frameCount: Số frames trong stack
    /// - Returns: Refined depth map với sub-pixel positions
    func refineSubPixel(depthMap: [Float],
                        focusStack: [[Float]],
                        frameCount: Int) -> [Float] {
        let pixelCount = depthMap.count
        var refined = depthMap
        
        for pixelIdx in 0..<pixelCount {
            let frameIdx = Int(depthMap[pixelIdx])
            
            // Cần ít nhất 1 frame ở mỗi phía để interpolate
            guard frameIdx > 0 && frameIdx < frameCount - 1 else { continue }
            
            let s0 = focusStack[frameIdx - 1][pixelIdx]  // frame trước
            let s1 = focusStack[frameIdx    ][pixelIdx]  // frame hiện tại (đỉnh)
            let s2 = focusStack[frameIdx + 1][pixelIdx]  // frame sau
            
            // Fit parabola y = ax² + bx + c qua 3 điểm
            // Đỉnh parabola tại x = -b/2a
            let denominator = s0 - 2 * s1 + s2
            
            // Tránh divide by zero khi 3 điểm thẳng hàng
            guard abs(denominator) > 1e-6 else { continue }
            
            let offset = 0.5 * (s0 - s2) / denominator
            
            // Clamp offset về [-0.5, 0.5] để không nhảy qua frame khác
            refined[pixelIdx] = Float(frameIdx) + simd_clamp(offset, -0.5, 0.5)
        }
        
        return refined
    }
}
```

---

## 8. Advanced — Alignment Improvements

**Priority:** 🟢 Enhancement (cho stack chụp tay / chủ thể có chuyển động nhỏ)  
**Effort:** 1–2 tuần  
**Expected improvement:** Loại bỏ ghosting tại vùng cánh hoa, lông, vải

### Vấn đề hiện tại

Feature-based alignment (SIFT/ORB-like) hoạt động tốt với tripod cứng và chủ thể bất động. Thất bại khi:
- Hoa "thở" do gió nhẹ
- Rung tripod micro
- Chủ thể di chuyển nhẹ giữa các frame

### Giải pháp: ECC (Enhanced Correlation Coefficient)

ECC tối ưu trực tiếp correlation coefficient trong ảnh domain — ổn định hơn feature matching khi có lighting variation nhỏ và chuyển động nhỏ đều khắp ảnh.

Apple Vision framework có `VNHomographicImageRegistrationRequest` sử dụng thuật toán tương tự ECC — **không cần implement từ đầu**.

**File:** `Sources/HeyFoSCore/Processing/ImageAligner.swift`

```swift
import Vision

extension ImageAligner {
    
    /// ECC-based alignment dùng Vision framework.
    /// Tốt hơn feature-based cho chuyển động nhỏ và uniform.
    func alignWithECC(source: CGImage, target: CGImage) async throws -> CGAffineTransform {
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNHomographicImageRegistrationRequest(
                targetedCGImage: target,
                options: [:]
            )
            
            let handler = VNImageRequestHandler(cgImage: source, options: [:])
            
            do {
                try handler.perform([request])
                
                guard let result = request.results?.first as? VNImageHomographicAlignmentObservation else {
                    continuation.resume(throwing: AlignmentError.noResult)
                    return
                }
                
                // Chuyển homography matrix → CGAffineTransform
                let warpTransform = result.warpTransform
                let affine = CGAffineTransform(
                    a:  CGFloat(warpTransform.columns.0.x),
                    b:  CGFloat(warpTransform.columns.0.y),
                    c:  CGFloat(warpTransform.columns.1.x),
                    d:  CGFloat(warpTransform.columns.1.y),
                    tx: CGFloat(warpTransform.columns.2.x),
                    ty: CGFloat(warpTransform.columns.2.y)
                )
                
                continuation.resume(returning: affine)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    /// Strategy pattern: thử ECC trước, fallback về feature-based nếu thất bại
    func alignAdaptive(source: CGImage, target: CGImage) async throws -> CGAffineTransform {
        do {
            return try await alignWithECC(source: source, target: target)
        } catch {
            // Log để monitor tỷ lệ fallback
            logger.warning("ECC alignment failed, falling back to feature-based: \(error)")
            return try await alignFeatureBased(source: source, target: target)
        }
    }
}
```

---

## 9. Advanced — Neural Blending Path

**Priority:** 🟢 Enhancement (roadmap dài hạn)  
**Effort:** 3–4 tuần  
**Expected improvement:** Vượt pyramid blending trên texture phức tạp (lông, vải, tóc)

### Kiến trúc đề xuất: Lightweight DeepFuse variant

Thay vì dùng model lớn (DeepFuse gốc), train một lightweight encoder-decoder đặc thù cho focus stacking. Input: 2 ảnh cần blend + focus confidence map. Output: blended result.

```
Input stack → chunked pairs → Encoder → Bottleneck → Decoder → Blended output
                                 ↑ focus confidence map (từ ensemble focus measure)
```

### Tích hợp với Core ML (native Apple Silicon)

```swift
import CoreML

class NeuralBlender {
    private let model: MLModel
    
    init() throws {
        // Model được convert sang .mlpackage từ PyTorch/ONNX
        let config = MLModelConfiguration()
        config.computeUnits = .all  // tự động dùng ANE khi có thể
        
        self.model = try FocusBlenderNet(configuration: config).model
    }
    
    func blend(frameA: CVPixelBuffer,
               frameB: CVPixelBuffer,
               confidenceA: CVPixelBuffer) throws -> CVPixelBuffer {
        let input = FocusBlenderNetInput(
            frame_a: frameA,
            frame_b: frameB,
            confidence_a: confidenceA
        )
        return try model.prediction(from: input).blended_output
    }
}
```

> **Lưu ý training data:** Thu thập synthetic pairs từ ảnh in-focus + simulated defocus blur. Ground truth = ảnh gốc in-focus. Dataset 5,000–10,000 pairs là đủ cho lightweight model.

---

## 10. Testing & Validation Framework

### Metrics định lượng để đo cải tiến

Mỗi fix phải được đo bằng số cụ thể, không chỉ "trông đẹp hơn":

| Metric | Đo gì | Công cụ |
|---|---|---|
| SSIM | Structural similarity vs reference | `vImage_SSIM` hoặc Python scikit-image |
| PSNR | Peak signal-to-noise ratio | Tính từ MSE |
| Halo area | Diện tích pixel có artifact | Binary mask + pixel count |
| Edge sharpness | MTF (Modulation Transfer Function) tại edge | Slanted edge analysis |

**File:** `Tests/HeyFoSCoreTests/QualityMetricsTests.swift`

```swift
import XCTest
@testable import HeyFoSCore

class QualityMetricsTests: XCTestCase {
    
    /// Test dataset: stack ảnh ốc sên 31 frames (file test cố định)
    let testStackURL = Bundle.module.url(forResource: "snail_shell_31frames",
                                         withExtension: nil)!
    
    func testSpecularSuppressionReducesHalo() async throws {
        let stackWithout = try await processStack(enableSpecular: false)
        let stackWith    = try await processStack(enableSpecular: true)
        
        // Đo diện tích halo tại vùng ROI (miệng lỗ tròn)
        let haloROI = CGRect(x: 0.35, y: 0.02, width: 0.30, height: 0.20)
        
        let haloAreaBefore = measureHaloArea(stackWithout, roi: haloROI)
        let haloAreaAfter  = measureHaloArea(stackWith,    roi: haloROI)
        
        // Kỳ vọng: halo giảm ít nhất 50%
        XCTAssertLessThan(haloAreaAfter, haloAreaBefore * 0.50,
            "Specular suppression should reduce halo area by at least 50%")
    }
    
    func testGuidedFilterPreservesEdgeSharpness() async throws {
        let resultGaussian = try await processStack(weightSmoother: .gaussian(radius: 1.0))
        let resultGuided   = try await processStack(weightSmoother: .guided(radius: 8))
        
        // Edge sharpness tại vùng vân xoắn
        let edgeROI = CGRect(x: 0.2, y: 0.3, width: 0.6, height: 0.4)
        
        let sharpnessGaussian = measureEdgeSharpness(resultGaussian, roi: edgeROI)
        let sharpnessGuided   = measureEdgeSharpness(resultGuided,   roi: edgeROI)
        
        // Guided filter phải cho edge sắc hơn hoặc bằng Gaussian
        XCTAssertGreaterThanOrEqual(sharpnessGuided, sharpnessGaussian * 0.95)
    }
    
    func testSSIMImprovement() async throws {
        // Reference = Helicon Focus output (ground truth)
        guard let reference = loadReferenceImage("helicon_snail_reference") else {
            throw XCTSkip("Reference image not available")
        }
        
        let resultBefore = try await processStack(useNewAlgorithms: false)
        let resultAfter  = try await processStack(useNewAlgorithms: true)
        
        let ssimBefore = computeSSIM(resultBefore, reference: reference)
        let ssimAfter  = computeSSIM(resultAfter,  reference: reference)
        
        print("SSIM before: \(ssimBefore), after: \(ssimAfter)")
        
        // SSIM phải cải thiện ít nhất 5%
        XCTAssertGreaterThan(ssimAfter, ssimBefore * 1.05)
    }
}
```

### Regression test bằng ảnh cố định

Lưu các ảnh test stack vào `Tests/HeyFoSCoreTests/Resources/`:

```
snail_shell_31frames/     ← stack ảnh ốc sên hiện tại
insect_eye_20frames/      ← mắt côn trùng (nhiều specular nhỏ)
flower_15frames/          ← cánh hoa (texture mềm, có chuyển động nhỏ)
```

Với mỗi stack, lưu kết quả "approved" sau khi fix. CI sẽ so sánh output mới vs approved và báo khi quality giảm.

---

## 11. Implementation Timeline

### Sprint 1 — 1 tuần (loại bỏ artifact rõ nhất)

| Task | Effort | Owner | Expected result |
|---|---|---|---|
| Test quick wins (thay đổi tham số) | 0.5 ngày | BE | Baseline measurement |
| Fix 1: Specular suppression Metal shader | 1.5 ngày | BE | Halo giảm 80% |
| Fix 2: Tăng blur_radius default lên 2.5 | 0.5 ngày | BE | Ringing giảm ngay |
| Viết test `testSpecularSuppressionReducesHalo` | 0.5 ngày | BE | Regression coverage |
| Update frontend: thêm "Subject type" preset | 1 ngày | FE | UX cải thiện |

### Sprint 2 — 1.5 tuần (cải thiện depth map)

| Task | Effort | Owner |
|---|---|---|
| Fix 3: Ensemble focus measure | 2 ngày | BE |
| Fix 4: Color consistency normalization | 2 ngày | BE |
| Fix 5: Sub-pixel parabolic interpolation | 1 ngày | BE |
| Thêm SSIM metric vào test suite | 1 ngày | BE |

### Sprint 3 — 2 tuần (nền tảng dài hạn)

| Task | Effort | Owner |
|---|---|---|
| Fix 2: Guided filter Swift implementation | 3 ngày | BE |
| Advanced alignment với Vision framework | 3 ngày | BE |
| Performance benchmark sau tất cả fixes | 1 ngày | BE |
| Documentation update | 1 ngày | BE |

---

## Appendix — Tham số recommended theo loại ảnh

```swift
// Preset configs — đề xuất thêm vào ProcessRequest

extension ProcessRequest {
    static var presetMacroHardSurface: ProcessRequest {
        // Ốc, vỏ sò, đá, kim loại — nhiều specular, edge cứng
        ProcessRequest(
            depthMapAlgorithm: "tenengrad",
            blendingAlgorithm: "pyramid",
            pyramidLevels: 5,
            blurRadius: 2.8,
            specularThreshold: 0.90,
            enableSpecularSuppression: true
        )
    }
    
    static var presetMacroSoftSurface: ProcessRequest {
        // Hoa, lông, côn trùng — ít specular, texture mềm
        ProcessRequest(
            depthMapAlgorithm: "ensemble",
            blendingAlgorithm: "pyramid",
            pyramidLevels: 6,
            blurRadius: 2.0,
            specularThreshold: 0.96,
            enableSpecularSuppression: true
        )
    }
    
    static var presetScientific: ProcessRequest {
        // Chụp khoa học — cần accuracy cao nhất, tốc độ không quan trọng
        ProcessRequest(
            depthMapAlgorithm: "ensemble",
            blendingAlgorithm: "pyramid",
            pyramidLevels: 7,
            blurRadius: 3.0,
            specularThreshold: 0.88,
            enableSpecularSuppression: true
        )
    }
}
```

---

*Document maintained by: AI Analysis based on HeyFoS v0.1 codebase + comparison image.*  
*Last updated: March 2026*  
*Next review: After Sprint 1 completion*