import Metal
import CoreGraphics
import Foundation

/// Alignment checker - analyze misalignment between image frames
public class AlignmentChecker {
    
    private let context: MetalContext
    
    public init(context: MetalContext) {
        self.context = context
    }
    
    /// Check alignment by computing frame differences
    /// Returns: Array of (frame_index, max_shift_x, max_shift_y, difference_score)
    public func analyzeAlignment(images: [MTLTexture]) throws -> [(index: Int, shiftX: Float, shiftY: Float, diffScore: Float)] {
        guard images.count >= 2 else {
            return []
        }
        
        var results: [(Int, Float, Float, Float)] = []
        let referenceImage = images[0]
        
        print("Analyzing alignment with reference image (index 0)...")
        
        for i in 1..<images.count {
            let testImage = images[i]
            
            // Compute phase correlation to estimate shift
            let (shiftX, shiftY, correlation) = try estimateShift(
                reference: referenceImage,
                target: testImage
            )
            
            results.append((i, shiftX, shiftY, correlation))
            
            print("  Frame \(i): shift=(\(String(format: "%.2f", shiftX)), \(String(format: "%.2f", shiftY))) px, correlation=\(String(format: "%.4f", correlation))")
        }
        
        return results
    }
    
    /// Estimate shift between two images using simple correlation
    private func estimateShift(reference: MTLTexture, target: MTLTexture) throws -> (Float, Float, Float) {
        // For now, use a simple center-crop correlation approach
        // In production, use phase correlation or feature matching
        
        let width = min(reference.width, target.width)
        let height = min(reference.height, target.height)
        
        // Sample center region (1024x1024 or smaller)
        let sampleSize = min(1024, min(width, height))
        let centerX = width / 2
        let centerY = height / 2
        let startX = centerX - sampleSize / 2
        let startY = centerY - sampleSize / 2
        
        // Read pixel data for comparison
        let refData = try readTextureRegion(reference, x: startX, y: startY, width: sampleSize, height: sampleSize)
        let targetData = try readTextureRegion(target, x: startX, y: startY, width: sampleSize, height: sampleSize)
        
        // Compute simple difference
        var totalDiff: Float = 0
        for i in 0..<(sampleSize * sampleSize * 4) {
            let diff = refData[i] - targetData[i]
            totalDiff += abs(diff)
        }
        
        let avgDiff = totalDiff / Float(sampleSize * sampleSize * 4)
        
        // For now, return (0, 0) shift with difference score
        // TODO: Implement proper phase correlation or feature matching
        return (0, 0, avgDiff)
    }
    
    /// Read a region of texture to CPU memory
    private func readTextureRegion(_ texture: MTLTexture, x: Int, y: Int, width: Int, height: Int) throws -> [Float] {
        let bytesPerRow = width * 4 * MemoryLayout<Float>.size
        var pixelData = [Float](repeating: 0, count: width * height * 4)
        
        let region = MTLRegion(
            origin: MTLOrigin(x: x, y: y, z: 0),
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
    
    /// Generate difference visualization between two images
    public func createDifferenceMap(reference: MTLTexture, target: MTLTexture) throws -> MTLTexture {
        let width = min(reference.width, target.width)
        let height = min(reference.height, target.height)
        
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: width,
            height: height,
            mipmapped: false
        )
        textureDescriptor.usage = [.shaderRead, .shaderWrite]
        
        guard let outputTexture = context.device.makeTexture(descriptor: textureDescriptor) else {
            throw NSError(domain: "AlignmentChecker", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create output texture"])
        }
        
        // Create compute pipeline for difference
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;
        
        kernel void compute_difference(
            texture2d<float, access::read> reference [[texture(0)]],
            texture2d<float, access::read> target [[texture(1)]],
            texture2d<float, access::write> output [[texture(2)]],
            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
                return;
            }
            
            float4 ref = reference.read(gid);
            float4 tgt = target.read(gid);
            
            // Compute absolute difference
            float4 diff = abs(ref - tgt);
            
            // Amplify for visualization (multiply by 5)
            diff *= 5.0;
            diff.a = 1.0;
            
            output.write(diff, gid);
        }
        """
        
        let library = try context.device.makeLibrary(source: shaderSource, options: nil)
        let function = library.makeFunction(name: "compute_difference")!
        let pipeline = try context.device.makeComputePipelineState(function: function)
        
        // Execute
        guard let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw NSError(domain: "AlignmentChecker", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create command buffer"])
        }
        
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(reference, index: 0)
        encoder.setTexture(target, index: 1)
        encoder.setTexture(outputTexture, index: 2)
        
        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (width + 15) / 16,
            height: (height + 15) / 16,
            depth: 1
        )
        
        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        return outputTexture
    }
}
