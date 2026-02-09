import Metal
import MetalKit
import Logging

/// Computes focus quality measures for focus stacking
public final class FocusMeasureProcessor {
    private let metalContext: MetalContext
    private let logger = Logger(label: "com.heyfos.focus")
    
    public enum Method {
        case laplacian
        case tenengrad
    }
    
    public init(metalContext: MetalContext) {
        self.metalContext = metalContext
    }
    
    /// Compute focus measure map for an image
    /// - Parameters:
    ///   - inputTexture: Input image texture (grayscale or RGB)
    ///   - method: Focus measure algorithm to use
    /// - Returns: Focus measure map texture (higher values = more in focus)
    public func computeFocusMeasure(
        inputTexture: MTLTexture,
        method: Method = .laplacian
    ) throws -> MTLTexture {
        logger.debug("Computing focus measure using \(method)")
        
        // Create output texture
        guard let outputTexture = metalContext.makeTexture(
            width: inputTexture.width,
            height: inputTexture.height,
            pixelFormat: .rgba32Float
        ) else {
            throw MetalError.textureCreationFailed
        }
        
        // Select pipeline
        let pipeline: MTLComputePipelineState?
        switch method {
        case .laplacian:
            pipeline = metalContext.laplacianPipeline
        case .tenengrad:
            pipeline = metalContext.tenengradPipeline
        }
        
        guard let pipeline = pipeline else {
            throw MetalError.pipelineCreationFailed("Focus measure pipeline not available")
        }
        
        // Create command buffer
        guard let commandBuffer = metalContext.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalError.commandBufferCreationFailed
        }
        
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(inputTexture, index: 0)
        encoder.setTexture(outputTexture, index: 1)
        
        // Calculate thread group size
        let threadGroupSize = MTLSize(
            width: 16,
            height: 16,
            depth: 1
        )
        
        let threadGroups = MTLSize(
            width: (inputTexture.width + threadGroupSize.width - 1) / threadGroupSize.width,
            height: (inputTexture.height + threadGroupSize.height - 1) / threadGroupSize.height,
            depth: 1
        )
        
        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()
        
        commandBuffer.commit()
        // Remove waitUntilCompleted - let GPU work async
        // Only wait when CPU needs to read the result
        
        logger.debug("Focus measure compute submitted to GPU")
        return outputTexture
    }
    
    /// Convert RGB texture to grayscale (required for some focus measures)
    public func convertToGrayscale(inputTexture: MTLTexture) throws -> MTLTexture {
        guard let pipeline = metalContext.rgbToGrayscalePipeline else {
            throw MetalError.pipelineCreationFailed("Grayscale pipeline not available")
        }
        
        guard let outputTexture = metalContext.makeTexture(
            width: inputTexture.width,
            height: inputTexture.height,
            pixelFormat: .rgba32Float
        ) else {
            throw MetalError.textureCreationFailed
        }
        
        guard let commandBuffer = metalContext.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalError.commandBufferCreationFailed
        }
        
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(inputTexture, index: 0)
        encoder.setTexture(outputTexture, index: 1)
        
        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (inputTexture.width + 15) / 16,
            height: (inputTexture.height + 15) / 16,
            depth: 1
        )
        
        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()
        
        commandBuffer.commit()
        // Remove wait - async GPU execution
        
        return outputTexture
    }
}
