import Foundation
import Metal
import Logging

/// Implementation of Depth Map (Max Fusion) blending
/// Algorithm: Pixel-level selection based on highest focus score
public class DepthMap {
    private let context: MetalContext
    private let logger = Logger(label: "com.heyfos.depthmap")
    
    public init(context: MetalContext) {
        self.context = context
    }
    
    public func blend(
        images: [MTLTexture],
        focusMaps: [MTLTexture],
        verbose: Bool = false
    ) throws -> MTLTexture {
        guard images.count == focusMaps.count, !images.isEmpty else {
            throw StackProcessingError.invalidInput
        }
        
        if verbose {
            logger.info("Performing DepthMap blending on \(images.count) images...")
        }
        
        return try blendGPU(images: images, focusMaps: focusMaps)
    }
    
    private func blendGPU(images: [MTLTexture], focusMaps: [MTLTexture]) throws -> MTLTexture {
        let width = images[0].width
        let height = images[0].height
        
        // 1. Create accumulation textures
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: width,
            height: height,
            mipmapped: false
        )
        textureDescriptor.usage = [.shaderRead, .shaderWrite]
        
        guard let bestScoreTexture = context.device.makeTexture(descriptor: textureDescriptor),
              let resultTexture = context.device.makeTexture(descriptor: textureDescriptor) else {
             throw NSError(domain: "DepthMap", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create working textures"])
        }
        
        // Initialize best scores to -1
        try clearTexture(bestScoreTexture, value: -1.0)
        
        // Intermediate texture for blurred focus map (reduces noise)
        guard let blurredFocusMap = context.makeTexture(width: width, height: height, pixelFormat: .rgba32Float) else {
             throw NSError(domain: "DepthMap", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create temp texture"])
        }
        
        // 2. Setup GPU Pipeline
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;
        
        kernel void max_fusion_update(
            texture2d<float, access::read> newImage [[texture(0)]],
            texture2d<float, access::read> newFocus [[texture(1)]],
            texture2d<float, access::read_write> bestScore [[texture(2)]],
            texture2d<float, access::read_write> resultImage [[texture(3)]],
            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= resultImage.get_width() || gid.y >= resultImage.get_height()) {
                return;
            }
            
            float currentMax = bestScore.read(gid).r;
            float newScore = newFocus.read(gid).r; // Assuming focus is in R channel
            
            if (newScore > currentMax) {
                // Update best score
                bestScore.write(float4(newScore, 0, 0, 1), gid);
                
                // Update result image
                float4 color = newImage.read(gid);
                color.a = 1.0; // Ensure opaque
                resultImage.write(color, gid);
            }
        }
        """
        
        let library = try context.device.makeLibrary(source: shaderSource, options: nil)
        let function = library.makeFunction(name: "max_fusion_update")!
        let maxFusionPipeline = try context.device.makeComputePipelineState(function: function)
        
        guard let commandBuffer = context.commandQueue.makeCommandBuffer() else {
            throw NSError(domain: "DepthMap", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create command buffer"])
        }
        
        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (width + 15) / 16,
            height: (height + 15) / 16,
            depth: 1
        )
        
        // 3. Process all images
        for i in 0..<images.count {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { continue }
            
            // Step 3a: Blur the focus map (Noise Reduction)
            if let blurPipeline = context.gaussianBlurPipeline {
                encoder.setComputePipelineState(blurPipeline)
                encoder.setTexture(focusMaps[i], index: 0) // Input
                encoder.setTexture(blurredFocusMap, index: 1) // Output
                encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
            } else {
                 // Fallback copy if blur pipeline missing (shouldn't happen)
                 // Or just modify logic to point to original. 
                 // For simplicity, we assume pipeline exists or we just rely on next step using original if we didn't write to blurred.
                 // Actually, let's explicitly copy or just bind the original if blur is missing.
                 // But for this edit, we assume blur works.
            }
            
            // We need a memory barrier or separate encoders if there's a dependency?
            // Metal tracks dependencies within command buffer between encoders if resources match.
            // But we can't switch pipelines in one encoder if they have check logic. 
            // Better: One encoder for Blur, One for Fusion? Or one big encoder switching pipelines?
            // Switch pipelines is fine.
            
            // Wait, we need to ensure the write to blurredFocusMap is done before reading it?
            // In the same command buffer, separate encoders guarantee order.
            // Inside SAME encoder: need memory barrier.
            encoder.memoryBarrier(scope: .textures)
            
            // Step 3b: Max Fusion Update
            encoder.setComputePipelineState(maxFusionPipeline)
            encoder.setTexture(images[i], index: 0)
            // Use the blurred map if we have the pipeline, otherwise the original
            if context.gaussianBlurPipeline != nil {
                encoder.setTexture(blurredFocusMap, index: 1)
            } else {
                encoder.setTexture(focusMaps[i], index: 1)
            }
            encoder.setTexture(bestScoreTexture, index: 2)
            encoder.setTexture(resultTexture, index: 3)
            
            encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
            encoder.endEncoding()
        }
        
        commandBuffer.commit()
        // CRITICAL: Must wait for GPU to finish rendering result texture
        commandBuffer.waitUntilCompleted()
        
        return resultTexture
    }
    
    /// Helper to clear a texture to specific value
    private func clearTexture(_ texture: MTLTexture, value: Float) throws {
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void clear_val(
            texture2d<float, access::write> out [[texture(0)]], 
            constant float &val [[buffer(0)]],
            uint2 gid [[thread_position_in_grid]]) 
        {
            if (gid.x < out.get_width() && gid.y < out.get_height()) {
                out.write(float4(val, 0, 0, 1), gid);
            }
        }
        """
        let lib = try context.device.makeLibrary(source: shaderSource, options: nil)
        let pipeline = try context.device.makeComputePipelineState(function: lib.makeFunction(name: "clear_val")!)
        
        guard let cmd = context.commandQueue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(pipeline)
        enc.setTexture(texture, index: 0)
        var v = value
        enc.setBytes(&v, length: MemoryLayout<Float>.size, index: 0)
        
        let groups = MTLSize(width: (texture.width+15)/16, height: (texture.height+15)/16, depth: 1)
        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        enc.endEncoding()
        cmd.commit()
    }
}

