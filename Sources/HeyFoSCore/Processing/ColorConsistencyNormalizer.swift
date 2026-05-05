import Metal
import MetalPerformanceShaders
import Accelerate
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
    kernel void scale_exposure(
        texture2d<float, access::read>  input  [[texture(0)]],
        texture2d<float, access::write> output [[texture(1)]],
        constant float &scale [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
        float4 px = input.read(gid);
        px = float4(clamp(px.rgb * scale, 0.0, 1.0), px.a);
        output.write(px, gid);
    }
    """

    init(context: MetalContext) {
        self.context = context
        let lib = try! context.device.makeLibrary(
            source: ColorConsistencyNormalizer.scaleShaderSrc, options: nil)
        scalePipeline = try! context.device.makeComputePipelineState(
            function: lib.makeFunction(name: "scale_exposure")!)
    }

    /// Returns a new array of textures with matched luminance.
    /// The middle frame is used as the reference and is returned unchanged.
    func normalize(_ images: [MTLTexture]) throws -> [MTLTexture] {
        guard images.count > 1 else { return images }

        let referenceIdx = images.count / 2
        let refMean = try computeMeanLuminance(images[referenceIdx])
        logger.info("Color consistency: reference frame \(referenceIdx) mean luminance = \(String(format: "%.4f", refMean))")

        return try images.enumerated().map { (i, img) in
            if i == referenceIdx { return img }

            let frameMean = try computeMeanLuminance(img)
            guard frameMean > 1e-6 else { return img }

            let rawScale = refMean / frameMean
            // Clamp to avoid extreme corrections for legitimate exposure differences
            let scale = Float(min(max(rawScale, 0.70), 1.40))

            if abs(scale - 1.0) < 0.02 {
                return img  // No meaningful correction needed
            }

            logger.debug("  Frame \(i): mean=\(String(format: "%.4f", frameMean)) scale=\(String(format: "%.3f", scale))")
            return try applyLuminanceScale(img, scale: scale)
        }
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

    /// Apply a uniform RGB scale correction via a Metal kernel.
    private func applyLuminanceScale(_ texture: MTLTexture, scale: Float) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat,
            width: texture.width, height: texture.height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]

        guard let outTex = context.device.makeTexture(descriptor: desc) else {
            return texture
        }

        guard let cmdBuf = context.commandQueue.makeCommandBuffer(),
              let enc = cmdBuf.makeComputeCommandEncoder() else {
            return texture
        }

        enc.setComputePipelineState(scalePipeline)
        enc.setTexture(texture, index: 0)
        enc.setTexture(outTex, index: 1)
        var s = scale
        enc.setBytes(&s, length: MemoryLayout<Float>.size, index: 0)

        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let tgCount = MTLSize(
            width: (texture.width + 15) / 16,
            height: (texture.height + 15) / 16,
            depth: 1
        )
        enc.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tg)
        enc.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        return outTex
    }
}
