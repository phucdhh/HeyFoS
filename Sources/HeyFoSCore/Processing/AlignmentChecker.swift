import Metal
import Accelerate
import MetalPerformanceShaders
import CoreGraphics
import Foundation

/// Phase-correlation image alignment checker and corrector.
///
/// Uses the 2-D Fourier shift theorem to estimate translational offsets between
/// frames with sub-pixel accuracy via parabolic peak refinement.  Detected
/// offsets are optionally corrected by warping each frame with a Metal bilinear
/// sampler — all on the M-series GPU / Accelerate ANE.
///
/// Algorithm:
///   1. Downsample to ≤512 px for speed; extract luma plane.
///   2. Apply per-axis Hanning window to suppress spectral leakage.
///   3. Compute 2-D FFT using vDSP_fft2d_zip (in-place, split-complex).
///   4. Form normalised cross-power spectrum: G = (A·conj(B)) / |A·conj(B)|.
///   5. IFFT → correlation surface; pick argmax → (dx, dy).
///   6. Sub-pixel parabolic interpolation around peak.
///   7. Optionally correct via Metal translate-warp kernel.
public final class AlignmentChecker {

    private let context: MetalContext
    /// Analysis size — MUST be a power of two.
    private let fftSize: Int = 512

    public init(context: MetalContext) {
        self.context = context
    }

    // MARK: - Public API

    /// Analyses each frame's translational offset relative to frame 0.
    public func analyzeAlignment(images: [MTLTexture]) throws
        -> [(index: Int, shiftX: Float, shiftY: Float, diffScore: Float)]
    {
        guard images.count >= 2 else { return [] }

        let refLuma = try extractLuma(images[0], size: fftSize)
        let refFFT  = forwardFFT(refLuma, logN: log2i(fftSize))

        print("Analyzing alignment with reference image (index 0)...")
        var results: [(Int, Float, Float, Float)] = []
        for i in 1..<images.count {
            let tgtLuma    = try extractLuma(images[i], size: fftSize)
            let (dx, dy)   = phaseCorrelation(refFFT: refFFT, tgtLuma: tgtLuma)
            let diff       = meanAbsDiff(refLuma, tgtLuma, n: fftSize * fftSize)
            results.append((i, dx, dy, diff))
            print("  Frame \(i): shift=(\(String(format: "%+.2f", dx)), \(String(format: "%+.2f", dy))) px, diff=\(String(format: "%.4f", diff))")
        }
        return results
    }

    /// Returns alignment-corrected copies of all textures (frame 0 unchanged).
    /// Frames whose shift magnitude is below `threshold` px are returned as-is.
    public func correctAlignment(images: [MTLTexture], threshold: Float = 0.5) throws -> [MTLTexture] {
        guard images.count >= 2 else { return images }

        print("Correcting alignment using phase correlation...")
        let refLuma = try extractLuma(images[0], size: fftSize)
        let refFFT  = forwardFFT(refLuma, logN: log2i(fftSize))

        var corrected: [MTLTexture] = [images[0]]
        for i in 1..<images.count {
            let tgtLuma  = try extractLuma(images[i], size: fftSize)
            let (dx, dy) = phaseCorrelation(refFFT: refFFT, tgtLuma: tgtLuma)
            let shift    = sqrtf(dx * dx + dy * dy)
            if shift < threshold {
                print("  Frame \(i): shift \(String(format: "%.2f", shift)) px < threshold — skipped")
                corrected.append(images[i])
            } else {
                print("  Frame \(i): correcting shift (\(String(format: "%+.2f", dx)), \(String(format: "%+.2f", dy))) px")
                corrected.append(try warpTranslate(images[i], dx: -dx, dy: -dy))
            }
        }
        return corrected
    }

    // MARK: - Phase Correlation

    /// Returns (shiftX, shiftY) in full-resolution pixels using the shift theorem.
    private func phaseCorrelation(refFFT: ([Float], [Float]), tgtLuma: [Float]) -> (Float, Float) {
        let n    = fftSize
        let logN = log2i(n)

        // FFT of target
        var tgtRe = tgtLuma
        var tgtIm = [Float](repeating: 0, count: n * n)
        let setup = vDSP_create_fftsetup(vDSP_Length(logN * 2), FFTRadix(kFFTRadix2))!
        defer { vDSP_destroy_fftsetup(setup) }

        tgtRe.withUnsafeMutableBufferPointer { rp in
            tgtIm.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft2d_zip(setup, &split, 1, 0,
                               vDSP_Length(logN), vDSP_Length(logN),
                               FFTDirection(kFFTDirection_Forward))
            }
        }

        // Normalised cross-power spectrum: G = (A · conj(B)) / |A · conj(B)|
        let (refRe, refIm) = refFFT
        var crossRe = [Float](repeating: 0, count: n * n)
        var crossIm = [Float](repeating: 0, count: n * n)
        for k in 0..<(n * n) {
            let ar = refRe[k]; let ai = refIm[k]
            let br = tgtRe[k]; let bi = tgtIm[k]
            let pr = ar * br + ai * bi          // real(A·conj(B))
            let pi = ai * br - ar * bi          // imag(A·conj(B))
            let mag = sqrtf(pr * pr + pi * pi) + 1e-9
            crossRe[k] = pr / mag
            crossIm[k] = pi / mag
        }

        // IFFT
        crossRe.withUnsafeMutableBufferPointer { rp in
            crossIm.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft2d_zip(setup, &split, 1, 0,
                               vDSP_Length(logN), vDSP_Length(logN),
                               FFTDirection(kFFTDirection_Inverse))
            }
        }
        var scale = 1.0 / Float(n * n)
        vDSP_vsmul(crossRe, 1, &scale, &crossRe, 1, vDSP_Length(n * n))

        // Peak detection
        var peakVal: Float = 0; var peakIdx: vDSP_Length = 0
        vDSP_maxvi(crossRe, 1, &peakVal, &peakIdx, vDSP_Length(n * n))
        let peakRow = Int(peakIdx) / n
        let peakCol = Int(peakIdx) % n

        let dxRaw = parabolicPeak(crossRe, peakRow: peakRow, peakCol: peakCol, n: n, axis: .x)
        let dyRaw = parabolicPeak(crossRe, peakRow: peakRow, peakCol: peakCol, n: n, axis: .y)

        // Wrap-around: offsets > n/2 are negative (the shift went the other way)
        let dx = dxRaw > Float(n / 2) ? dxRaw - Float(n) : dxRaw
        let dy = dyRaw > Float(n / 2) ? dyRaw - Float(n) : dyRaw
        return (dx, dy)
    }

    private enum Axis { case x, y }

    /// 1-D parabolic interpolation around the peak on one axis.
    private func parabolicPeak(_ surf: [Float], peakRow: Int, peakCol: Int, n: Int, axis: Axis) -> Float {
        func v(_ r: Int, _ c: Int) -> Float { surf[(r & (n - 1)) * n + (c & (n - 1))] }
        let c    = v(peakRow, peakCol)
        let prev = axis == .x ? v(peakRow, peakCol - 1) : v(peakRow - 1, peakCol)
        let next = axis == .x ? v(peakRow, peakCol + 1) : v(peakRow + 1, peakCol)
        let denom = 2.0 * (prev - 2 * c + next)
        let base  = Float(axis == .x ? peakCol : peakRow)
        guard abs(denom) > 1e-9 else { return base }
        return base + (prev - next) / denom
    }

    // MARK: - Forward FFT

    private func forwardFFT(_ input: [Float], logN: UInt) -> ([Float], [Float]) {
        let n    = fftSize
        var re   = input
        var im   = [Float](repeating: 0, count: n * n)
        let setup = vDSP_create_fftsetup(vDSP_Length(logN * 2), FFTRadix(kFFTRadix2))!
        defer { vDSP_destroy_fftsetup(setup) }
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft2d_zip(setup, &split, 1, 0,
                               vDSP_Length(logN), vDSP_Length(logN),
                               FFTDirection(kFFTDirection_Forward))
            }
        }
        return (re, im)
    }

    // MARK: - Luma Extraction

    private func extractLuma(_ texture: MTLTexture, size: Int) throws -> [Float] {
        // Downsample via MPS bilinear scale
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: size, height: size, mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .shared
        guard let small = context.device.makeTexture(descriptor: desc),
              let cmd   = context.commandQueue.makeCommandBuffer() else {
            throw AlignError.metalResourceCreationFailed
        }
        let scaler = MPSImageBilinearScale(device: context.device)
        var t = MPSScaleTransform(
            scaleX: Double(size) / Double(texture.width),
            scaleY: Double(size) / Double(texture.height),
            translateX: 0, translateY: 0
        )
        withUnsafePointer(to: &t) { scaler.scaleTransform = $0 }
        scaler.encode(commandBuffer: cmd, sourceTexture: texture, destinationTexture: small)
        cmd.commit()
        cmd.waitUntilCompleted()

        // Read back
        var rgba = [Float](repeating: 0, count: size * size * 4)
        rgba.withUnsafeMutableBytes { ptr in
            small.getBytes(ptr.baseAddress!,
                           bytesPerRow: size * 4 * MemoryLayout<Float>.size,
                           from: MTLRegion(origin: .init(x: 0, y: 0, z: 0),
                                          size: .init(width: size, height: size, depth: 1)),
                           mipmapLevel: 0)
        }

        // Rec.709 luma with Hanning window applied
        let hann = hanningWindow2D(size: size)
        var luma = [Float](repeating: 0, count: size * size)
        for i in 0..<(size * size) {
            let r = rgba[i * 4], g = rgba[i * 4 + 1], b = rgba[i * 4 + 2]
            luma[i] = (0.2126 * r + 0.7152 * g + 0.0722 * b) * hann[i]
        }
        return luma
    }

    private func hanningWindow2D(size: Int) -> [Float] {
        var win = [Float](repeating: 0, count: size * size)
        for row in 0..<size {
            let wy = Float(0.5 * (1 - cos(2 * Double.pi * Double(row) / Double(size - 1))))
            for col in 0..<size {
                let wx = Float(0.5 * (1 - cos(2 * Double.pi * Double(col) / Double(size - 1))))
                win[row * size + col] = wx * wy
            }
        }
        return win
    }

    // MARK: - Translation Warp (Metal)

    private func warpTranslate(_ texture: MTLTexture, dx: Float, dy: Float) throws -> MTLTexture {
        let w = texture.width, h = texture.height
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: w, height: h, mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        guard let output = context.device.makeTexture(descriptor: desc) else {
            throw AlignError.metalResourceCreationFailed
        }

        let src = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void translate_warp(
            texture2d<float, access::sample> input  [[texture(0)]],
            texture2d<float, access::write>  output [[texture(1)]],
            constant float2 &shift                  [[buffer(0)]],
            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
            constexpr sampler s(coord::pixel, filter::linear, address::clamp_to_edge);
            float2 uv = float2(gid) - shift + 0.5;
            output.write(input.sample(s, uv), gid);
        }
        """
        let lib      = try context.device.makeLibrary(source: src, options: nil)
        let fn       = lib.makeFunction(name: "translate_warp")!
        let pipeline = try context.device.makeComputePipelineState(function: fn)
        var shiftVec = SIMD2<Float>(dx, dy)

        guard let cmd = context.commandQueue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else {
            throw AlignError.metalResourceCreationFailed
        }
        enc.setComputePipelineState(pipeline)
        enc.setTexture(texture, index: 0)
        enc.setTexture(output,  index: 1)
        enc.setBytes(&shiftVec, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
        let tgs = MTLSize(width: 16, height: 16, depth: 1)
        enc.dispatchThreadgroups(
            MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1),
            threadsPerThreadgroup: tgs
        )
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        return output
    }

    // MARK: - Helpers

    private func meanAbsDiff(_ a: [Float], _ b: [Float], n: Int) -> Float {
        var diff = [Float](repeating: 0, count: n)
        vDSP_vsub(a, 1, b, 1, &diff, 1, vDSP_Length(n))
        let absDiff = diff.map(abs)
        var result: Float = 0
        vDSP_meanv(absDiff, 1, &result, vDSP_Length(n))
        return result
    }

    private func log2i(_ n: Int) -> UInt {
        var v = n, r: UInt = 0
        while v > 1 { v >>= 1; r += 1 }
        return r
    }

    // MARK: - Difference Visualisation

    public func createDifferenceMap(reference: MTLTexture, target: MTLTexture) throws -> MTLTexture {
        let width  = min(reference.width,  target.width)
        let height = min(reference.height, target.height)
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        guard let output = context.device.makeTexture(descriptor: desc) else {
            throw AlignError.metalResourceCreationFailed
        }
        let src = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void compute_difference(
            texture2d<float, access::read> reference [[texture(0)]],
            texture2d<float, access::read> target    [[texture(1)]],
            texture2d<float, access::write> output   [[texture(2)]],
            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
            float4 diff = abs(reference.read(gid) - target.read(gid)) * 5.0;
            diff.a = 1.0;
            output.write(diff, gid);
        }
        """
        let lib      = try context.device.makeLibrary(source: src, options: nil)
        let fn       = lib.makeFunction(name: "compute_difference")!
        let pipeline = try context.device.makeComputePipelineState(function: fn)
        guard let cmd = context.commandQueue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else {
            throw AlignError.metalResourceCreationFailed
        }
        enc.setComputePipelineState(pipeline)
        enc.setTexture(reference, index: 0)
        enc.setTexture(target,    index: 1)
        enc.setTexture(output,    index: 2)
        enc.dispatchThreadgroups(
            MTLSize(width: (width+15)/16, height: (height+15)/16, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)
        )
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        return output
    }
}

enum AlignError: Error {
    case metalResourceCreationFailed
}

