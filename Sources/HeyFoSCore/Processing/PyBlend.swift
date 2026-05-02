import Metal
import CoreGraphics
import Foundation
import MetalPerformanceShaders

/// Pyramid blending for high-quality focus stacking
/// Uses multi-scale Laplacian pyramid to reduce halos and improve edge quality
/// Renamed to PyBlend for consistency with project terminology
public class PyBlend {
    
    private let context: MetalContext
    private let levels: Int      // Number of pyramid levels
    private let blurRadius: Double  // Gaussian blur radius for focus map pre-processing
    
    // 7 levels: fine frequency decomposition matching Zerene PMax depth of detail
    public init(context: MetalContext, levels: Int = 7, blurRadius: Double = 2.5) {
        self.context = context
        self.levels = levels
        self.blurRadius = blurRadius
    }
    
    /// Blend images using Laplacian pyramid method
    /// - Parameters:
    ///   - images: Input images (already aligned)
    ///   - focusMaps: Focus quality maps for each image
    /// - Returns: Blended output texture
    public func blend(images: [MTLTexture], focusMaps: [MTLTexture]) throws -> MTLTexture {
        guard images.count == focusMaps.count, !images.isEmpty else {
            throw NSError(domain: "PyramidBlending", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid input"])
        }
        
        let _ = images[0].width
        
        print("Pyramid blending: \(images.count) images, \(levels) levels")
                // Step 0: (focus maps no longer used — base level now uses local variance like ShineStacker)
        // Step 1: Build Gaussian pyramids for each image
        print("  [1/3] Building Gaussian pyramids...")
        var gaussianPyramids: [[MTLTexture]] = []
        for image in images {
            let pyramid = try buildGaussianPyramid(image)
            gaussianPyramids.append(pyramid)
        }
        
        // Step 2: Build Laplacian pyramids from Gaussian pyramids
        print("  [2/3] Building Laplacian pyramids...")
        var laplacianPyramids: [[MTLTexture]] = []
        for pyramid in gaussianPyramids {
            let laplacian = try buildLaplacianPyramid(gaussianPyramid: pyramid)
            laplacianPyramids.append(laplacian)
        }
        gaussianPyramids.removeAll()
        
        // Step 3: Blend using ShineStacker's per-level algorithm:
        // - Detail levels: convolve(gray²) → hard WTA (fuse_laplacian)
        // - Base level: local variance → hard WTA (get_fused_base / deviation)
        print("  [3/3] Blending pyramids (ShineStacker per-level energy)...")
        let blendedPyramid = try blendPyramidsPerLevelEnergy(
            laplacianPyramids: laplacianPyramids,
            baseWeightPyramids: []
        )
        
        laplacianPyramids.removeAll()
        
        // Step 4: Collapse pyramid to final image
        print("  Collapsing pyramid to final image...")
        let result = try collapsePyramid(blendedPyramid)
        
        // CRITICAL: Wait for ALL GPU operations to complete before returning
        if let commandBuffer = context.commandQueue.makeCommandBuffer() {
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
        }
        
        return result
    }
    
    /// Build Gaussian pyramid (repeated downsampling)
    private func buildGaussianPyramid(_ image: MTLTexture) throws -> [MTLTexture] {
        var pyramid: [MTLTexture] = [image]
        var currentImage = image
        
        for _ in 1..<levels {
            let downsampledImage = try gaussianDownsample(currentImage)
            pyramid.append(downsampledImage)
            currentImage = downsampledImage
        }
        
        return pyramid
    }
    
    /// Build Laplacian pyramid (difference between levels)
    private func buildLaplacianPyramid(gaussianPyramid: [MTLTexture]) throws -> [MTLTexture] {
        var laplacianPyramid: [MTLTexture] = []
        
        for i in 0..<(gaussianPyramid.count - 1) {
            let current = gaussianPyramid[i]
            let next = gaussianPyramid[i + 1]
            
            // Upsample next level and subtract from current
            let upsampled = try upsample(next, targetWidth: current.width, targetHeight: current.height)
            let difference = try subtract(current, upsampled)
            
            laplacianPyramid.append(difference)
        }
        
        // Add the smallest Gaussian level as the last Laplacian level
        laplacianPyramid.append(gaussianPyramid.last!)
        
        return laplacianPyramid
    }
    
    /// Build weight pyramid (Gaussian pyramid of focus map)
    private func buildWeightPyramid(_ focusMap: MTLTexture) throws -> [MTLTexture] {
        // MUST use Gaussian downsampling (same kernel as image pyramid) per Burt & Adelson 1983.
        // Box/average downsampling creates aliased weight edges at each level → halos at all scales.
        var pyramid: [MTLTexture] = [focusMap]
        var currentImage = focusMap
        
        for _ in 1..<levels {
            let downsampledImage = try gaussianDownsample(currentImage)
            pyramid.append(downsampledImage)
            currentImage = downsampledImage
        }
        
        return pyramid
    }
    
    /// Downsample using Gaussian blur (standard pyramid reduction)


    /// Removed old maxPoolDownsample in favor of gaussianDownsample
    
    /// ShineStacker-style blending: per-level energy for detail, focus map for base
    private func blendPyramidsPerLevelEnergy(laplacianPyramids: [[MTLTexture]], baseWeightPyramids: [[MTLTexture]]) throws -> [MTLTexture] {
        let numLevels = laplacianPyramids[0].count
        var blendedPyramid: [MTLTexture] = []
        
        for level in 0..<numLevels {
            let isBase = (level == numLevels - 1)
            var laplacianLevels: [MTLTexture] = []
            var weightLevels: [MTLTexture] = []
            
            for i in 0..<laplacianPyramids.count {
                laplacianLevels.append(laplacianPyramids[i][level])
                if isBase {
                    // Base: ShineStacker get_fused_base — use local variance (deviation) as weight
                    let variance = try computeLocalVariance(laplacianPyramids[i][level])
                    weightLevels.append(variance)
                } else {
                    // Detail: exact ShineStacker fuse_laplacian — convolve(gray*gray), no sqrt
                    let energy = try computeSmoothedLaplacianEnergy(laplacianPyramids[i][level])
                    weightLevels.append(energy)
                }
            }
            
            let blended = try blendLevelWTA(laplacianLevels: laplacianLevels, weightLevels: weightLevels)
            blendedPyramid.append(blended)
        }
        
        return blendedPyramid
    }
    
    /// Exact ShineStacker fuse_laplacian energy: convolve(gray * gray), no sqrt.
    private func computeSmoothedLaplacianEnergy(_ laplacian: MTLTexture) throws -> MTLTexture {
        let width = laplacian.width
        let height = laplacian.height

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        guard let squaredTex = context.device.makeTexture(descriptor: desc) else {
            throw NSError(domain: "PyBlend", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create squared texture"])
        }

        let squareSrc = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void gray_squared(texture2d<float, access::read> lap [[texture(0)]],
                                  texture2d<float, access::write> out [[texture(1)]],
                                  uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
            float3 rgb = lap.read(gid).rgb;
            float gray = dot(rgb, float3(0.2126, 0.7152, 0.0722));
            out.write(float4(gray * gray, 0, 0, 1), gid);
        }
        """
        let sqLib = try context.device.makeLibrary(source: squareSrc, options: nil)
        let sqPipeline = try context.device.makeComputePipelineState(function: sqLib.makeFunction(name: "gray_squared")!)
        guard let sqCmd = context.commandQueue.makeCommandBuffer(),
              let sqEnc = sqCmd.makeComputeCommandEncoder() else {
            throw NSError(domain: "PyBlend", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create cmd buffer"])
        }
        sqEnc.setComputePipelineState(sqPipeline)
        sqEnc.setTexture(laplacian, index: 0)
        sqEnc.setTexture(squaredTex, index: 1)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        sqEnc.dispatchThreadgroups(MTLSize(width: (width+15)/16, height: (height+15)/16, depth: 1), threadsPerThreadgroup: tg)
        sqEnc.endEncoding()
        sqCmd.commit()
        sqCmd.waitUntilCompleted()

        // ShineStacker uses the Burt-Adelson convolve — approximate with Gaussian σ≈1.0
        return try gaussianBlur(squaredTex, radius: 3.0)
    }

    /// ShineStacker get_fused_base: local variance (deviation) for base-layer WTA.
    /// deviation(x) = mean(x²) - mean(x)² over a local patch
    private func computeLocalVariance(_ laplacian: MTLTexture) throws -> MTLTexture {
        let width = laplacian.width
        let height = laplacian.height

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        guard let grayTex = context.device.makeTexture(descriptor: desc),
              let gray2Tex = context.device.makeTexture(descriptor: desc) else {
            throw NSError(domain: "PyBlend", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create variance textures"])
        }

        // Extract grayscale and gray² in one pass
        let src = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void extract_gray_gray2(
            texture2d<float, access::read> inp [[texture(0)]],
            texture2d<float, access::write> outG [[texture(1)]],
            texture2d<float, access::write> outG2 [[texture(2)]],
            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= outG.get_width() || gid.y >= outG.get_height()) return;
            float3 rgb = inp.read(gid).rgb;
            float g = dot(rgb, float3(0.2126, 0.7152, 0.0722));
            outG.write(float4(g, 0, 0, 1), gid);
            outG2.write(float4(g * g, 0, 0, 1), gid);
        }
        """
        let lib = try context.device.makeLibrary(source: src, options: nil)
        let pipe = try context.device.makeComputePipelineState(function: lib.makeFunction(name: "extract_gray_gray2")!)
        guard let cmd = context.commandQueue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else {
            throw NSError(domain: "PyBlend", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed cmd"])
        }
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let tgc = MTLSize(width: (width+15)/16, height: (height+15)/16, depth: 1)
        enc.setComputePipelineState(pipe)
        enc.setTexture(laplacian, index: 0)
        enc.setTexture(grayTex, index: 1)
        enc.setTexture(gray2Tex, index: 2)
        enc.dispatchThreadgroups(tgc, threadsPerThreadgroup: tg)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        // Blur both to get local mean and local mean-square
        let meanG  = try gaussianBlur(grayTex,  radius: 3.0)
        let meanG2 = try gaussianBlur(gray2Tex, radius: 3.0)

        // variance = max(0, meanG2 - meanG²)
        let varDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: width, height: height, mipmapped: false)
        varDesc.usage = [.shaderRead, .shaderWrite]
        guard let varTex = context.device.makeTexture(descriptor: varDesc) else {
            throw NSError(domain: "PyBlend", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed var tex"])
        }
        let varSrc = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void local_variance(
            texture2d<float, access::read> meanG  [[texture(0)]],
            texture2d<float, access::read> meanG2 [[texture(1)]],
            texture2d<float, access::write> out   [[texture(2)]],
            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
            float mg  = meanG.read(gid).r;
            float mg2 = meanG2.read(gid).r;
            float v = max(mg2 - mg * mg, 0.0f);
            out.write(float4(v, 0, 0, 1), gid);
        }
        """
        let varLib  = try context.device.makeLibrary(source: varSrc, options: nil)
        let varPipe = try context.device.makeComputePipelineState(function: varLib.makeFunction(name: "local_variance")!)
        guard let cmd2 = context.commandQueue.makeCommandBuffer(),
              let enc2 = cmd2.makeComputeCommandEncoder() else {
            throw NSError(domain: "PyBlend", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed cmd2"])
        }
        enc2.setComputePipelineState(varPipe)
        enc2.setTexture(meanG, index: 0)
        enc2.setTexture(meanG2, index: 1)
        enc2.setTexture(varTex, index: 2)
        enc2.dispatchThreadgroups(tgc, threadsPerThreadgroup: tg)
        enc2.endEncoding()
        cmd2.commit()
        cmd2.waitUntilCompleted()

        return varTex
    }
    
    /// Pure hard WTA blend — matches ShineStacker's fuse_laplacian/get_fused_base exactly.
    /// Weight source: per-level energy (details) or focus map (base). No threshold.
    private func blendLevelWTA(laplacianLevels: [MTLTexture], weightLevels: [MTLTexture]) throws -> MTLTexture {
        let width = laplacianLevels[0].width
        let height = laplacianLevels[0].height
        
        let accDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        accDesc.usage = [.shaderRead, .shaderWrite]
        guard let accValue = context.device.makeTexture(descriptor: accDesc),
              let accWeight = context.device.makeTexture(descriptor: accDesc) else {
            throw NSError(domain: "PyBlend", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create accumulators"])
        }
        try clearTexture(accValue)
        try clearTexture(accWeight)
        
        let shaderSrc = """
        #include <metal_stdlib>
        using namespace metal;
        
        // Hard WTA: keep the pixel with the highest weight per-pixel.
        kernel void wta_accumulate(
            texture2d<float, access::read> laplacian [[texture(0)]],
            texture2d<float, access::read> weight [[texture(1)]],
            texture2d<float, access::read_write> accVal [[texture(2)]],
            texture2d<float, access::read_write> accW [[texture(3)]],
            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= accVal.get_width() || gid.y >= accVal.get_height()) return;
            float w = weight.read(gid).r;
            float curW = accW.read(gid).r;
            if (w > curW) {
                accVal.write(laplacian.read(gid), gid);
                accW.write(float4(w, 0, 0, 1), gid);
            }
        }
        
        kernel void wta_finalize(
            texture2d<float, access::read> accVal [[texture(0)]],
            texture2d<float, access::write> output [[texture(1)]],
            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
            float4 v = accVal.read(gid);
            v.a = 1.0;
            output.write(v, gid);
        }
        """
        let lib = try context.device.makeLibrary(source: shaderSrc, options: nil)
        let accumPipeline = try context.device.makeComputePipelineState(function: lib.makeFunction(name: "wta_accumulate")!)
        let finPipeline   = try context.device.makeComputePipelineState(function: lib.makeFunction(name: "wta_finalize")!)
        
        let tg  = MTLSize(width: 16, height: 16, depth: 1)
        let tgc = MTLSize(width: (width+15)/16, height: (height+15)/16, depth: 1)
        
        guard let cmd = context.commandQueue.makeCommandBuffer() else {
            throw NSError(domain: "PyBlend", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create cmd buffer"])
        }
        
        // Accumulate: per-frame WTA
        for i in 0..<laplacianLevels.count {
            guard let enc = cmd.makeComputeCommandEncoder() else { continue }
            enc.setComputePipelineState(accumPipeline)
            enc.setTexture(laplacianLevels[i], index: 0)
            enc.setTexture(weightLevels[i], index: 1)
            enc.setTexture(accValue, index: 2)
            enc.setTexture(accWeight, index: 3)
            enc.dispatchThreadgroups(tgc, threadsPerThreadgroup: tg)
            enc.endEncoding()
        }
        
        // Finalize: output winning pixel
        let outDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        outDesc.usage = [.shaderRead, .shaderWrite]
        guard let output = context.device.makeTexture(descriptor: outDesc),
              let enc2 = cmd.makeComputeCommandEncoder() else {
            throw NSError(domain: "PyBlend", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create output texture"])
        }
        enc2.setComputePipelineState(finPipeline)
        enc2.setTexture(accValue, index: 0)
        enc2.setTexture(output, index: 1)
        enc2.dispatchThreadgroups(tgc, threadsPerThreadgroup: tg)
        enc2.endEncoding()
        cmd.commit()
        
        return output
    }

    /// Blend a single pyramid level using weighted accumulation on GPU
    private func blendLevel(laplacianLevels: [MTLTexture], weightLevels: [MTLTexture], isBase: Bool = false) throws -> MTLTexture {
        let width = laplacianLevels[0].width
        let height = laplacianLevels[0].height
        
        // 1. Create accumulation textures (High precision float for summation)
        let mode = MTLPixelFormat.rgba32Float
        let accDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: mode, width: width, height: height, mipmapped: false)
        accDesc.usage = [.shaderRead, .shaderWrite]
        
        guard let accValueTexture = context.device.makeTexture(descriptor: accDesc),
              let accWeightTexture = context.device.makeTexture(descriptor: accDesc) else {
            throw NSError(domain: "PyramidBlending", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create accumulation textures"])
        }
        
        // Initialize accumulators to 0
        try clearTexture(accValueTexture)
        try clearTexture(accWeightTexture) // Max weight tracker
        
        // 2. Setup GPU Pipeline for Accumulation
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;
        
        kernel void accumulate_level(
            texture2d<float, access::read> laplacian [[texture(0)]],
            texture2d<float, access::read> weight [[texture(1)]],
            texture2d<float, access::read_write> accValue [[texture(2)]],
            texture2d<float, access::read_write> accWeight [[texture(3)]],
            constant bool &isBase [[buffer(0)]],
            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= accValue.get_width() || gid.y >= accValue.get_height()) {
                return;
            }
            
            float4 lapVal = laplacian.read(gid);
            float w = max(0.0f, weight.read(gid).r);
            
            float4 curAccVal = accValue.read(gid);
            float curAccW = accWeight.read(gid).r;
            
            // Standard Burt-Adelson multi-scale blending
            accValue.write(curAccVal + lapVal * w, gid);
            accWeight.write(float4(curAccW + w, 0.0, 0.0, 1.0), gid);
        }
        
        kernel void finalize_level(
            texture2d<float, access::read> accValue [[texture(0)]],
            texture2d<float, access::read> accWeight [[texture(1)]],
            texture2d<float, access::write> output [[texture(2)]],
            constant uint &count [[buffer(0)]],
            constant bool &isBase [[buffer(1)]],
            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
                return;
            }
            
            float4 val = accValue.read(gid);
            float  w   = accWeight.read(gid).r;
            
            // Soft blend normalize
            if (w > 1e-6f) {
                val = val / w;
            }
            
            val.a = 1.0;
            output.write(val, gid);
        }
        """
        
        let library = try context.device.makeLibrary(source: shaderSource, options: nil)
        let accumulateFunction = library.makeFunction(name: "accumulate_level")!
        let finalizeFunction = library.makeFunction(name: "finalize_level")!
        
        let accumulatePipeline = try context.device.makeComputePipelineState(function: accumulateFunction)
        let finalizePipeline = try context.device.makeComputePipelineState(function: finalizeFunction)
        
        // 3. Accumulation Pass: Loop through all images
        guard let commandBuffer = context.commandQueue.makeCommandBuffer() else {
            throw NSError(domain: "PyramidBlending", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create cmd buffer"])
        }
        
        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (width + 15) / 16,
            height: (height + 15) / 16,
            depth: 1
        )
        
        // Batch accumulation commands
        var baseFlag = isBase
        for i in 0..<laplacianLevels.count {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { continue }
            encoder.setComputePipelineState(accumulatePipeline)
            encoder.setTexture(laplacianLevels[i], index: 0)
            encoder.setTexture(weightLevels[i], index: 1)
            encoder.setTexture(accValueTexture, index: 2)
            encoder.setTexture(accWeightTexture, index: 3)
            encoder.setBytes(&baseFlag, length: MemoryLayout<Bool>.stride, index: 0)
            encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
            encoder.endEncoding()
        }
        
        // 4. Finalize Pass: Normalize by total weight
        let outputDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        outputDesc.usage = [.shaderRead, .shaderWrite]
        guard let outputTexture = context.device.makeTexture(descriptor: outputDesc),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
             throw NSError(domain: "PyramidBlending", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create output texture"])
        }
        
        encoder.setComputePipelineState(finalizePipeline)
        encoder.setTexture(accValueTexture, index: 0)
        encoder.setTexture(accWeightTexture, index: 1)
        encoder.setTexture(outputTexture, index: 2)
        
        // Optional debugging count buffer (not currently used by shader logic but good practice to pass info)
        var count = UInt32(laplacianLevels.count)
        encoder.setBytes(&count, length: MemoryLayout<UInt32>.size, index: 0)
        var baseFlagFinal = isBase
        encoder.setBytes(&baseFlagFinal, length: MemoryLayout<Bool>.stride, index: 1)
        
        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()
        
        commandBuffer.commit()
        // No wait - let GPU work async
        
        return outputTexture
    }
    
    /// Helper to clear a texture to zero
    private func clearTexture(_ texture: MTLTexture) throws {
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void clear_tex(texture2d<float, access::write> out [[texture(0)]], uint2 gid [[thread_position_in_grid]]) {
            if (gid.x < out.get_width() && gid.y < out.get_height()) out.write(float4(0), gid);
        }
        """
        let lib = try context.device.makeLibrary(source: shaderSource, options: nil)
        let f = lib.makeFunction(name: "clear_tex")!
        let pipeline = try context.device.makeComputePipelineState(function: f)
        
        guard let cmd = context.commandQueue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(pipeline)
        enc.setTexture(texture, index: 0)
        let groups = MTLSize(width: (texture.width+15)/16, height: (texture.height+15)/16, depth: 1)
        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        enc.endEncoding()
        cmd.commit()
    }
    
    /// Binarize focused areas (Strict Winner-Takes-All).
    /// Giai đoạn 2: Áp đặt cơ chế "Winner-Takes-All" tuyệt đối.
    private func binarizeWeights(_ weights: [MTLTexture]) throws -> [MTLTexture] {
        guard weights.count > 1 else { return weights }
        let width = weights[0].width
        let height = weights[0].height

        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        kernel void compute_max_weight(
            texture2d<float, access::read>       weight [[texture(0)]],
            texture2d<float, access::read_write> maxW   [[texture(1)]],
            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= maxW.get_width() || gid.y >= maxW.get_height()) return;
            float w = max(0.0f, weight.read(gid).r);
            float currentMax = maxW.read(gid).r;
            if (w > currentMax) {
                maxW.write(float4(w, 0.0f, 0.0f, 1.0f), gid);
            }
        }

        kernel void compare_max(
            texture2d<float, access::read>  weight [[texture(0)]],
            texture2d<float, access::read>  maxW   [[texture(1)]],
            texture2d<float, access::write> output [[texture(2)]],
            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
            float w = max(0.0f, weight.read(gid).r);
            float m = maxW.read(gid).r;
            
            // Giữ lại 1.0 nếu là ảnh rõ nét nhất, ngoại trừ các điểm đen hoàn toàn
            float outW = 0.0f;
            if (m > 1e-6f && w >= m - 1e-6f) {
                outW = 1.0f;
            }
            output.write(float4(outW, outW, outW, 1.0f), gid);
        }
        """

        let lib = try context.device.makeLibrary(source: shaderSource, options: nil)
        let computeMaxPipeline = try context.device.makeComputePipelineState(function: lib.makeFunction(name: "compute_max_weight")!)
        let comparePipeline    = try context.device.makeComputePipelineState(function: lib.makeFunction(name: "compare_max")!)

        let tg      = MTLSize(width: 16, height: 16, depth: 1)
        let tgCount = MTLSize(width: (width+15)/16, height: (height+15)/16, depth: 1)

        // Create max weight tracker texture
        let maxDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: width, height: height, mipmapped: false)
        maxDesc.usage = [.shaderRead, .shaderWrite]
        guard let maxTexture = context.device.makeTexture(descriptor: maxDesc) else {
            throw NSError(domain: "PyBlend", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create max texture"])
        }
        try clearTexture(maxTexture)

        // Pass 1: compute max per pixel
        guard let cmd1 = context.commandQueue.makeCommandBuffer() else {
            throw NSError(domain: "PyBlend", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create cmd buffer"])
        }
        for weight in weights {
            guard let enc = cmd1.makeComputeCommandEncoder() else { continue }
            enc.setComputePipelineState(computeMaxPipeline)
            enc.setTexture(weight, index: 0)
            enc.setTexture(maxTexture, index: 1)
            enc.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tg)
            enc.endEncoding()
        }
        cmd1.commit()
        cmd1.waitUntilCompleted()

        // Pass 2: binarize output based on max
        var result: [MTLTexture] = []
        guard let cmd2 = context.commandQueue.makeCommandBuffer() else {
            throw NSError(domain: "PyBlend", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create cmd buffer"])
        }
        for weight in weights {
            let outDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
            outDesc.usage = [.shaderRead, .shaderWrite]
            guard let outTex = context.device.makeTexture(descriptor: outDesc) else {
                throw NSError(domain: "PyBlend", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create output texture"])
            }
            guard let enc = cmd2.makeComputeCommandEncoder() else { continue }
            enc.setComputePipelineState(comparePipeline)
            enc.setTexture(weight, index: 0)
            enc.setTexture(maxTexture, index: 1)
            enc.setTexture(outTex, index: 2)
            enc.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tg)
            enc.endEncoding()
            result.append(outTex)
        }
        cmd2.commit()
        cmd2.waitUntilCompleted()

        return result
    }

    /// Normalize focus map to [0, 1] range
    private func normalizeFocusMap(_ focusMap: MTLTexture) throws -> MTLTexture {
        
        let minMaxKernel = MPSImageStatisticsMinAndMax(device: context.device)
        let meanKernel = MPSImageStatisticsMeanAndVariance(device: context.device)
        
        // Output textures for stats
        // MinMax: 2x1 texture (Pixel 0 = Min, Pixel 1 = Max)
        // Mean: 2x1 texture (Pixel 0 = Mean, Pixel 1 = Variance)
        
        let statsDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: focusMap.pixelFormat, // Use same format (e.g. .r32Float)
            width: 2,
            height: 1,
            mipmapped: false
        )
        statsDescriptor.usage = [.shaderWrite, .shaderRead]
        // Ensure shared storage mode so CPU can read it easily (or copy efficiently)
        statsDescriptor.storageMode = .shared 
        
        guard let minMaxTexture = context.device.makeTexture(descriptor: statsDescriptor),
              let meanTexture = context.device.makeTexture(descriptor: statsDescriptor),
              let commandBuffer = context.commandQueue.makeCommandBuffer() else {
             throw NSError(domain: "PyBlend", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create stats resources"])
        }
        
        // Encode kernels
        minMaxKernel.encode(commandBuffer: commandBuffer, sourceTexture: focusMap, destinationTexture: minMaxTexture)
        meanKernel.encode(commandBuffer: commandBuffer, sourceTexture: focusMap, destinationTexture: meanTexture)
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted() // Must wait to read stats
        
        // Read results from tiny textures (fast)
        // 2 pixels * 4 components * 4 bytes = 32 bytes (if rgba)
        // The focusMap is likely R32Float or RGBA32Float.
        // MPS writes min/max to the channels of the pixel.
        // If source is single channel (R), it writes to R.
        
        // Let's assume R32Float for simplicity of reading, but check focusMap format.
        // Usually focusMap in this project is R32Float or RGBA32Float with value in R.
        
        // Helper to read float values
        func readValues(from texture: MTLTexture) -> [Float] {
            let count = texture.width * texture.height * 4 // Assuming potentially 4 channels per pixel if we read blindly
            var output = [Float](repeating: 0, count: count)
            texture.getBytes(&output, bytesPerRow: texture.width * 16, from: MTLRegionMake2D(0, 0, texture.width, 1), mipmapLevel: 0)
            return output
        }
        
        let minMaxData = readValues(from: minMaxTexture)
        let meanData = readValues(from: meanTexture)
        
        // Pixel 0 is Min, Pixel 1 is Max
        // If format is RGBA, we look at the relevant channel (R).
        // MPS documentation says:
        // "The global minimum value is stored in the first pixel... The global maximum used is stored in the second pixel..."
        // If the source image has 1 channel, the statistics are in the first channel of the destination.
        
        let minVal = minMaxData[0] // Min is at (0,0) - Red component
        let maxVal = minMaxData[4] // Max is at (1,0) - Red component (offset 4 floats)
        
        let avgVal = meanData[0]   // Mean is at (0,0) - Red component
        
        // Original logic:
        var effectiveMax = maxVal
        if maxVal > avgVal * 20.0 {
            effectiveMax = avgVal * 20.0
            print("  [Focus Normalization] Outlier detected. Max: \(maxVal), Avg: \(avgVal). Clamping to \(effectiveMax)")
        }
        
        // Create normalized texture
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: focusMap.width,
            height: focusMap.height,
            mipmapped: false
        )
        textureDescriptor.usage = [.shaderRead, .shaderWrite]
        
        guard let outputTexture = context.device.makeTexture(descriptor: textureDescriptor) else {
            throw NSError(domain: "PyramidBlending", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create texture"])
        }
        
        let range = effectiveMax - minVal
        
        // Define GPU Kernel for Normalization
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;
        
        kernel void normalize_focus(
            texture2d<float, access::read> input [[texture(0)]],
            texture2d<float, access::write> output [[texture(1)]],
            constant float &minVal [[buffer(0)]],
            constant float &range [[buffer(1)]],
            constant float &effectiveMax [[buffer(2)]],
            constant float &exponent [[buffer(3)]],
            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
                return;
            }
            
            // Handle uniform case or empty range
            if (range < 0.0001) {
                output.write(float4(1.0, 1.0, 1.0, 1.0), gid);
                return;
            }
            
            float val = input.read(gid).r;
            float clamped = min(val, effectiveMax);
            float normalized = (clamped - minVal) / range;
            float sharpened = pow(normalized, exponent);
            
            output.write(float4(sharpened, sharpened, sharpened, 1.0), gid);
        }
        """
        
        let library = try context.device.makeLibrary(source: shaderSource, options: nil)
        let function = library.makeFunction(name: "normalize_focus")!
        let pipeline = try context.device.makeComputePipelineState(function: function)
        
        guard let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw NSError(domain: "PyramidBlending", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create command buffer"])
        }
        
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(focusMap, index: 0)
        encoder.setTexture(outputTexture, index: 1)
        
        var minValParam = minVal
        var rangeParam = range
        var maxParam = effectiveMax
        // Higher exponent = sharper focus selection; out-of-focus areas contribute much less
        var exponentParam: Float = 2.5
        
        encoder.setBytes(&minValParam, length: MemoryLayout<Float>.size, index: 0)
        encoder.setBytes(&rangeParam, length: MemoryLayout<Float>.size, index: 1)
        encoder.setBytes(&maxParam, length: MemoryLayout<Float>.size, index: 2)
        encoder.setBytes(&exponentParam, length: MemoryLayout<Float>.size, index: 3)
        
        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (focusMap.width + 15) / 16,
            height: (focusMap.height + 15) / 16,
            depth: 1
        )
        
        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()
        
        commandBuffer.commit()
        // Async GPU - no wait needed
        
        return outputTexture
    }
    
    /// Collapse pyramid back to full-resolution image
    private func collapsePyramid(_ pyramid: [MTLTexture]) throws -> MTLTexture {
        // Start from the smallest level
        var current = pyramid.last!
        
        // Upsample and add each level
        for i in stride(from: pyramid.count - 2, through: 0, by: -1) {
            let level = pyramid[i]
            let upsampled = try upsample(current, targetWidth: level.width, targetHeight: level.height)
            current = try add(upsampled, level)
        }
        
        // Subtle sharpening only. High amounts amplify any residual halos.
        current = try unsharpMask(current, amount: 0.3, radius: 1.0)
        
        // Ensure alpha channel is 1.0
        current = try setAlphaToOne(current)
        
        return current
    }
    
    /// Set alpha channel to 1.0 for all pixels
    private func setAlphaToOne(_ texture: MTLTexture) throws -> MTLTexture {
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;
        
        kernel void set_alpha(
            texture2d<float, access::read> input [[texture(0)]],
            texture2d<float, access::write> output [[texture(1)]],
            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
                return;
            }
            
            float4 color = input.read(gid);
            color.a = 1.0;
            output.write(color, gid);
        }
        """
        
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: texture.width,
            height: texture.height,
            mipmapped: false
        )
        textureDescriptor.usage = [.shaderRead, .shaderWrite]
        
        guard let outputTexture = context.device.makeTexture(descriptor: textureDescriptor) else {
            throw NSError(domain: "PyramidBlending", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create texture"])
        }
        
        let library = try context.device.makeLibrary(source: shaderSource, options: nil)
        let function = library.makeFunction(name: "set_alpha")!
        let pipeline = try context.device.makeComputePipelineState(function: function)
        
        guard let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw NSError(domain: "PyramidBlending", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create command buffer"])
        }
        
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setTexture(outputTexture, index: 1)
        
        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (texture.width + 15) / 16,
            height: (texture.height + 15) / 16,
            depth: 1
        )
        
        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()
        
        commandBuffer.commit()
        // Async GPU - no wait needed
        
        return outputTexture
    }
    
    // MARK: - Texture Operations
    
    private func gaussianDownsample(_ texture: MTLTexture) throws -> MTLTexture {
        let newWidth = max(1, texture.width / 2)
        let newHeight = max(1, texture.height / 2)
        
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: newWidth,
            height: newHeight,
            mipmapped: false
        )
        textureDescriptor.usage = [.shaderRead, .shaderWrite]
        
        guard let outputTexture = context.device.makeTexture(descriptor: textureDescriptor) else {
            throw NSError(domain: "PyramidBlending", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create texture"])
        }
        
        // Use the existing Gaussian downsample kernel
        guard let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw NSError(domain: "PyramidBlending", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create command buffer"])
        }
        
        guard let pipeline = context.gaussianDownsamplePipeline else {
            throw NSError(domain: "PyramidBlending", code: -1, userInfo: [NSLocalizedDescriptionKey: "Gaussian downsample pipeline not available"])
        }
        
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setTexture(outputTexture, index: 1)
        
        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (newWidth + 15) / 16,
            height: (newHeight + 15) / 16,
            depth: 1
        )
        
        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()
        
        commandBuffer.commit()
        // Async GPU - no wait needed
        
        return outputTexture
    }
    
    /// Simple 2x2 average downsampling for weight pyramids
    /// Preserves sharp boundaries better than Gaussian blur
    private func averageDownsample(_ texture: MTLTexture) throws -> MTLTexture {
        let newWidth = max(1, texture.width / 2)
        let newHeight = max(1, texture.height / 2)
        
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: newWidth,
            height: newHeight,
            mipmapped: false
        )
        textureDescriptor.usage = [.shaderRead, .shaderWrite]
        
        guard let outputTexture = context.device.makeTexture(descriptor: textureDescriptor) else {
            throw NSError(domain: "PyramidBlending", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create texture"])
        }
        
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;
        
        kernel void average_downsample(
            texture2d<float, access::read> input [[texture(0)]],
            texture2d<float, access::write> output [[texture(1)]],
            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
                return;
            }
            
            // Sample 2x2 block from input
            int2 input_pos = int2(gid) * 2;
            
            float4 sum = float4(0.0);
            for (int dy = 0; dy < 2; dy++) {
                for (int dx = 0; dx < 2; dx++) {
                    int2 sample_pos = clamp(input_pos + int2(dx, dy), 
                                           int2(0), 
                                           int2(input.get_width()-1, input.get_height()-1));
                    sum += input.read(uint2(sample_pos));
                }
            }
            
            output.write(sum * 0.25, gid);
        }
        """
        
        let library = try context.device.makeLibrary(source: shaderSource, options: nil)
        let function = library.makeFunction(name: "average_downsample")!
        let pipeline = try context.device.makeComputePipelineState(function: function)
        
        guard let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw NSError(domain: "PyramidBlending", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create command buffer"])
        }
        
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setTexture(outputTexture, index: 1)
        
        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (newWidth + 15) / 16,
            height: (newHeight + 15) / 16,
            depth: 1
        )
        
        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()
        
        commandBuffer.commit()
        
        return outputTexture
    }
    
    private func upsample(_ texture: MTLTexture, targetWidth: Int, targetHeight: Int) throws -> MTLTexture {
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: targetWidth,
            height: targetHeight,
            mipmapped: false
        )
        textureDescriptor.usage = [.shaderRead, .shaderWrite]
        
        guard let outputTexture = context.device.makeTexture(descriptor: textureDescriptor) else {
            throw NSError(domain: "PyramidBlending", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create texture"])
        }
        
        // Burt-Adelson 1983 correct expand: zero-interleave then 4 * convolve.
        // kernel a=0.4: k = [0.05, 0.25, 0.40, 0.25, 0.05]
        // CRITICAL: must NOT normalize by kernel sum — the ×4 scale is energy-conserving.
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        kernel void ba_expand(
            texture2d<float, access::read>  input  [[texture(0)]],
            texture2d<float, access::write> output [[texture(1)]],
            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
            int ox = int(gid.x);
            int oy = int(gid.y);
            int sW = int(input.get_width());
            int sH = int(input.get_height());
            // Burt-Adelson a=0.4 generating kernel
            float k[5] = {0.05f, 0.25f, 0.40f, 0.25f, 0.05f};
            float4 sum = float4(0.0f);
            for (int dy = -2; dy <= 2; dy++) {
                for (int dx = -2; dx <= 2; dx++) {
                    // Position in expanded (zero-interleaved) grid
                    int ex = ox - dx;
                    int ey = oy - dy;
                    // Only even expanded positions have source values
                    if (((ex | ey) & 1) == 0) {
                        int sx = clamp(ex / 2, 0, sW - 1);
                        int sy = clamp(ey / 2, 0, sH - 1);
                        sum += input.read(uint2(sx, sy)) * (k[dx+2] * k[dy+2]);
                    }
                }
            }
            // ×4 factor from Burt-Adelson expand (energy conservation)
            sum *= 4.0f;
            sum.a = max(sum.a, 1.0f);
            output.write(sum, gid);
        }
        """
        
        let library = try context.device.makeLibrary(source: shaderSource, options: nil)
        let function = library.makeFunction(name: "ba_expand")!
        let pipeline = try context.device.makeComputePipelineState(function: function)
        
        guard let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw NSError(domain: "PyramidBlending", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create command buffer"])
        }
        
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setTexture(outputTexture, index: 1)
        
        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (targetWidth + 15) / 16,
            height: (targetHeight + 15) / 16,
            depth: 1
        )
        
        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()
        
        commandBuffer.commit()
        
        return outputTexture
    }
    
    private func subtract(_ a: MTLTexture, _ b: MTLTexture) throws -> MTLTexture {
        return try applyBinaryOp(a, b, operation: "a - b")
    }
    
    private func add(_ a: MTLTexture, _ b: MTLTexture) throws -> MTLTexture {
        return try applyBinaryOp(a, b, operation: "a + b")
    }
    
    private func applyBinaryOp(_ a: MTLTexture, _ b: MTLTexture, operation: String) throws -> MTLTexture {
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: a.width,
            height: a.height,
            mipmapped: false
        )
        textureDescriptor.usage = [.shaderRead, .shaderWrite]
        
        guard let outputTexture = context.device.makeTexture(descriptor: textureDescriptor) else {
            throw NSError(domain: "PyramidBlending", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create texture"])
        }
        
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;
        
        kernel void binary_op(
            texture2d<float, access::read> texA [[texture(0)]],
            texture2d<float, access::read> texB [[texture(1)]],
            texture2d<float, access::write> output [[texture(2)]],
            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
                return;
            }
            
            float4 a = texA.read(gid);
            float4 b = texB.read(gid);
            float4 result = \(operation);
            
            output.write(result, gid);
        }
        """
        
        let library = try context.device.makeLibrary(source: shaderSource, options: nil)
        let function = library.makeFunction(name: "binary_op")!
        let pipeline = try context.device.makeComputePipelineState(function: function)
        
        guard let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw NSError(domain: "PyramidBlending", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create command buffer"])
        }
        
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(a, index: 0)
        encoder.setTexture(b, index: 1)
        encoder.setTexture(outputTexture, index: 2)
        
        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (a.width + 15) / 16,
            height: (a.height + 15) / 16,
            depth: 1
        )
        
        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()
        
        commandBuffer.commit()
        // Async GPU - no wait needed
        
        return outputTexture
    }
    
    /// Apply unsharp mask for edge enhancement
    /// Formula: Output = Original + Amount * (Original - Blurred)
    private func unsharpMask(_ texture: MTLTexture, amount: Float = 0.8, radius: Float = 1.5) throws -> MTLTexture {
        // First, create a blurred version
        let blurred = try gaussianBlur(texture, radius: radius)
        
        // Then apply unsharp mask formula
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;
        
        kernel void unsharp_mask(
            texture2d<float, access::read> original [[texture(0)]],
            texture2d<float, access::read> blurred [[texture(1)]],
            texture2d<float, access::write> output [[texture(2)]],
            constant float &amount [[buffer(0)]],
            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
                return;
            }
            
            float4 orig = original.read(gid);
            float4 blur = blurred.read(gid);
            
            // Unsharp mask: Original + Amount * (Original - Blurred)
            float4 result = orig + amount * (orig - blur);
            
            // Clamp to valid range [0, 1] to prevent overshooting
            result = clamp(result, 0.0, 1.0);
            result.a = 1.0;
            
            output.write(result, gid);
        }
        """
        
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: texture.width,
            height: texture.height,
            mipmapped: false
        )
        textureDescriptor.usage = [.shaderRead, .shaderWrite]
        
        guard let outputTexture = context.device.makeTexture(descriptor: textureDescriptor) else {
            throw NSError(domain: "PyramidBlending", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create texture"])
        }
        
        let library = try context.device.makeLibrary(source: shaderSource, options: nil)
        let function = library.makeFunction(name: "unsharp_mask")!
        let pipeline = try context.device.makeComputePipelineState(function: function)
        
        guard let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw NSError(domain: "PyramidBlending", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create command buffer"])
        }
        
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setTexture(blurred, index: 1)
        encoder.setTexture(outputTexture, index: 2)
        
        var amountParam = amount
        encoder.setBytes(&amountParam, length: MemoryLayout<Float>.size, index: 0)
        
        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (texture.width + 15) / 16,
            height: (texture.height + 15) / 16,
            depth: 1
        )
        
        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()
        
        commandBuffer.commit()
        
        return outputTexture
    }
    
    /// Gaussian blur with configurable radius
    /// Gaussian blur using MPS (true Gaussian, not box approximation)
    private func gaussianBlur(_ texture: MTLTexture, radius: Float = 1.5) throws -> MTLTexture {
        // Map radius to sigma: for a Gaussian, 3σ ≈ radius, so σ = radius/3.
        // Clamp to minimum 0.5 to avoid degenerate kernel.
        let sigma = max(radius / 3.0, 0.5)
        let blur = MPSImageGaussianBlur(device: context.device, sigma: sigma)
        blur.edgeMode = .clamp

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat,
            width: texture.width,
            height: texture.height,
            mipmapped: false
        )
        textureDescriptor.usage = [.shaderRead, .shaderWrite]

        guard let outputTexture = context.device.makeTexture(descriptor: textureDescriptor) else {
            throw NSError(domain: "PyramidBlending", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create texture"])
        }

        guard let commandBuffer = context.commandQueue.makeCommandBuffer() else {
            throw NSError(domain: "PyramidBlending", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create command buffer"])
        }

        blur.encode(commandBuffer: commandBuffer, sourceTexture: texture, destinationTexture: outputTexture)
        commandBuffer.commit()

        return outputTexture
    }
    
    private func readTexture(_ texture: MTLTexture) throws -> [Float] {
        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 4 * MemoryLayout<Float>.size
        var pixelData = [Float](repeating: 0, count: width * height * 4)
        
        let region = MTLRegion(
            origin: MTLOrigin(x: 0, y: 0, z: 0),
            size: MTLSize(width: width, height: height, depth: 1)
        )
        
        pixelData.withUnsafeMutableBytes { ptr in
            texture.getBytes(
                ptr.baseAddress!,
                bytesPerRow: bytesPerRow,
                from: region,
                mipmapLevel: 0
            )
        }
        
        return pixelData
    }

    // MARK: - Guided Filter (edge-preserving weight smoothing)

    /// Applies a guided filter to the focus map `p` using `guidance` (an input image) as the
    /// edge reference.  This preserves focus-region boundaries while eliminating noise/ringing in
    /// the weight map — much better than a plain Gaussian blur for this purpose.
    ///
    /// - Parameters:
    ///   - p:         Input focus/weight map (single-channel RGBA where R carries the value).
    ///   - guidance:  Guiding image (RGBA32Float from the same frame).
    ///   - radius:    Box-filter half-width (in pixels). Higher → smoother but less edge-aware.
    ///   - eps:       Regularisation parameter. Smaller → sharper edges preserved.
    private func guidedFilter(_ p: MTLTexture, guidance: MTLTexture, radius: Int = 8, eps: Float = 0.01) throws -> MTLTexture {
        let w = p.width, h = p.height
        let boxW = radius * 2 + 1

        // Helper: create a working RGBA32Float texture
        func makeTex(_ ww: Int = w, _ hh: Int = h) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: ww, height: hh, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            return context.device.makeTexture(descriptor: d)
        }
        // Helper: box-filter one texture with MPS
        func boxBlur(_ input: MTLTexture, into output: MTLTexture) {
            let box = MPSImageBox(device: context.device, kernelWidth: boxW, kernelHeight: boxW)
            guard let cmd = context.commandQueue.makeCommandBuffer() else { return }
            box.encode(commandBuffer: cmd, sourceTexture: input, destinationTexture: output)
            cmd.commit()
            cmd.waitUntilCompleted()
        }

        // --- Guided filter 10-pass implementation ---
        // 1. mean_I  = box(I)
        // 2. mean_p  = box(p)
        // 3. mean_Ip = box(I * p)   [via pixel-multiply Metal kernel]
        // 4. mean_I2 = box(I * I)
        // 5. var_I   = mean_I2 − mean_I²
        // 6. cov_Ip  = mean_Ip − mean_I * mean_p
        // 7. a       = cov_Ip / (var_I + eps)
        // 8. b       = mean_p − a * mean_I
        // 9. mean_a  = box(a)
        // 10. mean_b = box(b)
        // 11. q      = mean_a * I + mean_b

        // Inline Metal kernel source for element-wise ops (one kernel handles many ops via a mode flag).
        let src = """
        #include <metal_stdlib>
        using namespace metal;

        // mode 0: c = a * b (each channel independently)
        // mode 1: c = a * b  (same — split just for clarity)
        // mode 2: c = a - b * b   (variance: mean_X2 - mean_X^2)
        // mode 3: c = a - b * c2  (covariance: mean_Ip - mean_I * mean_p)
        // mode 4: c = a / (b + eps)
        // mode 5: c = a - b * c2  (b  = mean_p, b*c2 = a * mean_I; b here is reused)
        // mode 6: c = a * b + c2   (final: mean_a * I + mean_b)

        struct Params { float eps; float padding[3]; };

        kernel void pointwise(
            texture2d<float, access::read>  A       [[texture(0)]],
            texture2d<float, access::read>  B       [[texture(1)]],
            texture2d<float, access::read>  C2      [[texture(2)]],
            texture2d<float, access::write> Out     [[texture(3)]],
            constant uint  &mode                    [[buffer(0)]],
            constant Params &params                 [[buffer(1)]],
            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= Out.get_width() || gid.y >= Out.get_height()) return;
            float4 a  = A.read(gid);
            float4 b  = B.read(gid);
            float4 c2 = C2.read(gid);
            float4 result;
            switch (mode) {
                case 0:  result = a * b;               break; // I*p or I*I
                case 1:  result = a - b * b;           break; // var_I = mean_I2 - mean_I^2
                case 2:  result = a - b * c2;          break; // cov_Ip = mean_Ip - mean_I*mean_p
                case 3:  result = a / (b + params.eps);break; // a = cov/var
                case 4:  result = c2 - a * b;          break; // b_coeff = mean_p - a*mean_I
                case 5:  result = a * b + c2;          break; // q = mean_a*I + mean_b
                default: result = a;                   break;
            }
            result.a = 1.0;
            Out.write(result, gid);
        }
        """
        let lib = try context.device.makeLibrary(source: src, options: nil)
        let fn  = lib.makeFunction(name: "pointwise")!
        let pl  = try context.device.makeComputePipelineState(function: fn)

        struct GFParams { var eps: Float; var pad: (Float,Float,Float) = (0,0,0) }
        var gfp = GFParams(eps: eps)
        let tgs = MTLSize(width: 16, height: 16, depth: 1)
        let tgc = MTLSize(width: (w+15)/16, height: (h+15)/16, depth: 1)

        func dispatch(mode: UInt32, A: MTLTexture, B: MTLTexture, C2: MTLTexture? = nil, out: MTLTexture) throws {
            guard let cmd = context.commandQueue.makeCommandBuffer(),
                  let enc = cmd.makeComputeCommandEncoder() else { return }
            let emptyDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 1, height: 1, mipmapped: false)
            emptyDesc.usage = [.shaderRead, .shaderWrite]
            let dummy = C2 ?? context.device.makeTexture(descriptor: emptyDesc)!
            enc.setComputePipelineState(pl)
            enc.setTexture(A, index: 0)
            enc.setTexture(B, index: 1)
            enc.setTexture(dummy, index: 2)
            enc.setTexture(out, index: 3)
            var m = mode
            enc.setBytes(&m, length: 4, index: 0)
            enc.setBytes(&gfp, length: MemoryLayout<GFParams>.size, index: 1)
            enc.dispatchThreadgroups(tgc, threadsPerThreadgroup: tgs)
            enc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
        }

        guard let meanI  = makeTex(), let meanP  = makeTex(),
              let Ip     = makeTex(), let meanIp = makeTex(),
              let I2     = makeTex(), let meanI2 = makeTex(),
              let varI   = makeTex(), let covIp  = makeTex(),
              let aCoeff = makeTex(), let bCoeff = makeTex(),
              let meanA  = makeTex(), let meanB  = makeTex(),
              let output = makeTex() else {
            // Fallback: return Gaussian-blurred version
            return try gaussianBlur(p, radius: Float(radius) * 0.5)
        }

        boxBlur(guidance, into: meanI)   // mean_I
        boxBlur(p,        into: meanP)   // mean_p

        try dispatch(mode: 0, A: guidance, B: guidance, out: I2)   // I*I
        try dispatch(mode: 0, A: guidance, B: p,        out: Ip)   // I*p
        boxBlur(I2, into: meanI2)
        boxBlur(Ip, into: meanIp)

        try dispatch(mode: 1, A: meanI2, B: meanI,  out: varI)     // var_I   = mean_I2 - mean_I^2
        try dispatch(mode: 2, A: meanIp, B: meanI, C2: meanP, out: covIp) // cov = mean_Ip - mean_I*mean_p

        try dispatch(mode: 3, A: covIp, B: varI,   out: aCoeff)    // a = cov / (var + eps)
        try dispatch(mode: 4, A: aCoeff, B: meanI, C2: meanP, out: bCoeff) // b = mean_p - a*mean_I

        boxBlur(aCoeff, into: meanA)
        boxBlur(bCoeff, into: meanB)

        try dispatch(mode: 5, A: meanA, B: guidance, C2: meanB, out: output) // q = mean_a * I + mean_b
        return output
    }
}
