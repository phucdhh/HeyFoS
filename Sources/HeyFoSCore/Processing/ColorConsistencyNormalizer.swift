import Metal
import MetalPerformanceShaders
import Accelerate
import CoreGraphics
import ImageIO
import Logging

/// Normalizes exposure across an image stack before focus blending.
///
/// Focus breathing and per-frame exposure drift cause each RAW frame to have
/// a slightly different mean luminance. Blending without correction produces
/// a color cast in the final result. This processor matches every frame's
/// mean luminance to the reference (middle) frame using a simple Reinhard-style
/// uniform scale, which preserves color relationships while eliminating drift.
///
/// The scale is clamped to [0.70, 1.40] to avoid over-correcting frames
/// that are legitimately different (e.g., first/last frame of a long focus run).
final class ColorConsistencyNormalizer {
    private let context: MetalContext
    private let logger = Logger(label: "com.heyfos.color-consistency")
    private let scalePipeline: MTLComputePipelineState

    private static let scaleShaderSrc = """
    #include <metal_stdlib>
    using namespace metal;
    // read_write access — scales the texture in-place with no extra allocation
    kernel void scale_exposure_inplace(
        texture2d<float, access::read_write> tex   [[texture(0)]],
        constant float                      &scale [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= tex.get_width() || gid.y >= tex.get_height()) return;
        float4 px = tex.read(gid);
        px = float4(clamp(px.rgb * scale, 0.0, 1.0), px.a);
        tex.write(px, gid);
    }
    """

    init(context: MetalContext) {
        self.context = context
        let lib = try! context.device.makeLibrary(
            source: ColorConsistencyNormalizer.scaleShaderSrc, options: nil)
        scalePipeline = try! context.device.makeComputePipelineState(
            function: lib.makeFunction(name: "scale_exposure_inplace")!)
    }

    /// Returns a new array of textures with matched luminance.
    /// The middle frame is used as the reference and is returned unchanged.
    ///
    /// Uses 2 GPU round-trips for the whole stack instead of N:
    ///   Phase 1 — submit all N downscale ops, wait once, read back in parallel on CPU
    ///   Phase 2 — submit all scale ops (async, downstream GPU work sequences after them)
    func normalize(_ images: [MTLTexture]) throws -> [MTLTexture] {
        guard images.count > 1 else { return images }

        let referenceIdx = images.count / 2
        let smallSize    = 64
        let pixelCount   = smallSize * smallSize

        // ── Phase 1: submit all N downscale ops to GPU without waiting ──────────
        var smallTextures: [MTLTexture] = []
        smallTextures.reserveCapacity(images.count)
        let scaleFilter = MPSImageBilinearScale(device: context.device)
        var lastDownscaleCmd: MTLCommandBuffer?

        for img in images {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba32Float, width: smallSize, height: smallSize, mipmapped: false)
            desc.usage       = [.shaderRead, .shaderWrite]
            desc.storageMode = .shared
            guard let smallTex = context.device.makeTexture(descriptor: desc),
                  let cmdBuf   = context.commandQueue.makeCommandBuffer() else {
                return images   // allocation failure — skip normalization
            }
            var transform = MPSScaleTransform(
                scaleX: Double(smallSize) / Double(img.width),
                scaleY: Double(smallSize) / Double(img.height),
                translateX: 0, translateY: 0)
            withUnsafePointer(to: &transform) { scaleFilter.scaleTransform = $0 }
            scaleFilter.encode(commandBuffer: cmdBuf, sourceTexture: img, destinationTexture: smallTex)
            cmdBuf.commit()
            smallTextures.append(smallTex)
            lastDownscaleCmd = cmdBuf
        }

        // Single wait — Metal queue ordering guarantees all prior command buffers are done
        lastDownscaleCmd?.waitUntilCompleted()

        // ── Phase 2: parallel CPU readback + luminance computation ───────────────
        var luminances = [Double](repeating: 0, count: images.count)
        DispatchQueue.concurrentPerform(iterations: images.count) { i in
            var pixels = [Float](repeating: 0, count: pixelCount * 4)
            pixels.withUnsafeMutableBytes { ptr in
                smallTextures[i].getBytes(
                    ptr.baseAddress!,
                    bytesPerRow: smallSize * MemoryLayout<Float>.size * 4,
                    from: MTLRegionMake2D(0, 0, smallSize, smallSize),
                    mipmapLevel: 0)
            }
            var lumaArr = [Float](repeating: 0, count: pixelCount)
            for j in 0..<pixelCount {
                lumaArr[j] = 0.2126 * pixels[j * 4] + 0.7152 * pixels[j * 4 + 1] + 0.0722 * pixels[j * 4 + 2]
            }
            var mean: Float = 0
            vDSP_meanv(lumaArr, 1, &mean, vDSP_Length(pixelCount))
            luminances[i] = Double(mean)    // each i is unique — no data race
        }

        let refMean = luminances[referenceIdx]
        logger.info("Color consistency: reference frame \(referenceIdx) mean luminance = \(String(format: "%.4f", refMean))")

        // ── Phase 3: in-place scale on GPU — zero extra texture allocations ─────
        // Encoding all scale ops into one command buffer and committing once
        // avoids the per-frame waitUntilCompleted that caused the crash pattern.
        guard let batchCmd = context.commandQueue.makeCommandBuffer() else { return images }
        for (i, img) in images.enumerated() {
            if i == referenceIdx { continue }
            let frameMean = luminances[i]
            guard frameMean > 1e-6 else { continue }

            let rawScale = refMean / frameMean
            let scale    = Float(min(max(rawScale, 0.70), 1.40))
            if abs(scale - 1.0) < 0.02 { continue }

            logger.debug("  Frame \(i): mean=\(String(format: "%.4f", frameMean)) scale=\(String(format: "%.3f", scale))")

            guard let enc = batchCmd.makeComputeCommandEncoder() else { continue }
            enc.setComputePipelineState(scalePipeline)
            enc.setTexture(img, index: 0)   // read_write — same texture, no copy
            var s = scale
            enc.setBytes(&s, length: MemoryLayout<Float>.size, index: 0)
            let tg = MTLSize(width: 16, height: 16, depth: 1)
            let tgCount = MTLSize(
                width:  (img.width  + 15) / 16,
                height: (img.height + 15) / 16,
                depth: 1)
            enc.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tg)
            enc.endEncoding()
        }
        batchCmd.commit()
        batchCmd.waitUntilCompleted()

        // Return the same array — every texture was modified in-place
        return images
    }

    // MARK: - Streaming helpers (called once per image in the streaming pipeline)

    /// Pre-compute mean luminances for all images from tiny URL thumbnails only.
    /// No full-resolution images are loaded — uses CGImageSource 64×64 thumbnails.
    /// Runs concurrently. Safe to call before any MTLTexture work.
    func precomputeLuminancesFromURLs(_ urls: [URL]) -> [Double] {
        var results = [Double](repeating: 0.5, count: urls.count)
        let smallSize = 64
        DispatchQueue.concurrentPerform(iterations: urls.count) { i in
            // autoreleasepool: CGImageSourceCreateWithURL, CGImageSourceCreateThumbnailAtIndex,
            // and CGContext are Obj-C objects. Without this, they accumulate across all N
            // concurrent iterations before being freed.
            autoreleasepool {
                let opts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                    kCGImageSourceCreateThumbnailWithTransform:     false,
                    kCGImageSourceThumbnailMaxPixelSize:            smallSize
                ]
                guard let src = CGImageSourceCreateWithURL(urls[i] as CFURL, nil),
                      let cg  = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
                else { return }
                let w = cg.width, h = cg.height, n = w * h
                var raw = [UInt8](repeating: 0, count: n * 4)
                guard let ctx = CGContext(
                    data: &raw, width: w, height: h,
                    bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                ) else { return }
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
                var luma = 0.0
                for j in 0..<n {
                    luma += 0.2126 * Double(raw[j*4]) + 0.7152 * Double(raw[j*4+1]) + 0.0722 * Double(raw[j*4+2])
                }
                results[i] = luma / (Double(n) * 255.0)   // each i is unique — no data race
            }
        }
        return results
    }

    /// Compute the luminance scale factor for one frame relative to the reference.
    /// Returns 1.0 for the reference frame or when luminance is near zero.
    /// Scale is clamped to [0.70, 1.40] to prevent over-correction.
    func luminanceScale(frameIdx: Int, referenceIdx: Int, luminances: [Double]) -> Float {
        guard frameIdx != referenceIdx else { return 1.0 }
        let frameMean = luminances[frameIdx]
        let refMean   = luminances[referenceIdx]
        guard frameMean > 1e-6, refMean > 1e-6 else { return 1.0 }
        return Float(min(max(refMean / frameMean, 0.70), 1.40))
    }

    /// Apply in-place luminance scale to one texture on the GPU.
    /// No-op if |scale - 1| < 0.02.  Blocks until the GPU op completes.
    func applyScaleInPlace(_ texture: MTLTexture, scale: Float) throws {
        guard abs(scale - 1.0) >= 0.02 else { return }
        guard let cmd = context.commandQueue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(scalePipeline)
        enc.setTexture(texture, index: 0)
        var s = scale
        enc.setBytes(&s, length: MemoryLayout<Float>.size, index: 0)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        enc.dispatchThreadgroups(
            MTLSize(width: (texture.width+15)/16, height: (texture.height+15)/16, depth: 1),
            threadsPerThreadgroup: tg)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
    }

    // MARK: - Private

    /// Downsample to 64×64, read back to CPU, compute Rec.709 mean luminance.
    private func computeMeanLuminance(_ texture: MTLTexture) throws -> Double {
        let smallSize = 64
        let scaleFilter = MPSImageBilinearScale(device: context.device)

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: smallSize, height: smallSize,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .shared

        guard let smallTex = context.device.makeTexture(descriptor: desc),
              let cmdBuf = context.commandQueue.makeCommandBuffer() else {
            return 0.5
        }

        var transform = MPSScaleTransform(
            scaleX: Double(smallSize) / Double(texture.width),
            scaleY: Double(smallSize) / Double(texture.height),
            translateX: 0, translateY: 0
        )
        withUnsafePointer(to: &transform) { ptr in
            scaleFilter.scaleTransform = ptr
        }
        scaleFilter.encode(commandBuffer: cmdBuf, sourceTexture: texture, destinationTexture: smallTex)
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        let pixelCount = smallSize * smallSize
        var pixels = [Float](repeating: 0, count: pixelCount * 4)
        pixels.withUnsafeMutableBytes { ptr in
            smallTex.getBytes(
                ptr.baseAddress!,
                bytesPerRow: smallSize * 16,
                from: MTLRegionMake2D(0, 0, smallSize, smallSize),
                mipmapLevel: 0
            )
        }

        // Compute Rec.709 luminance: Y = 0.2126R + 0.7152G + 0.0722B
        var luma = [Float](repeating: 0, count: pixelCount)
        for i in 0..<pixelCount {
            let r = pixels[i * 4 + 0]
            let g = pixels[i * 4 + 1]
            let b = pixels[i * 4 + 2]
            luma[i] = 0.2126 * r + 0.7152 * g + 0.0722 * b
        }

        var mean: Float = 0
        vDSP_meanv(luma, 1, &mean, vDSP_Length(pixelCount))
        return Double(mean)
    }

    /// Apply a uniform RGB scale correction in-place via a Metal kernel.
    /// (Kept for backward compatibility; normalize() now uses the batch path above.)
    private func applyLuminanceScale(_ texture: MTLTexture, scale: Float) throws {
        guard let cmdBuf = context.commandQueue.makeCommandBuffer(),
              let enc    = cmdBuf.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(scalePipeline)
        enc.setTexture(texture, index: 0)
        var s = scale
        enc.setBytes(&s, length: MemoryLayout<Float>.size, index: 0)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let tgCount = MTLSize(
            width:  (texture.width  + 15) / 16,
            height: (texture.height + 15) / 16,
            depth: 1)
        enc.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tg)
        enc.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()
    }
}
