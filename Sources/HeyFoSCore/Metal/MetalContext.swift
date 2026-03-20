import Metal
import MetalKit
import Logging

/// Manages Metal device, command queue, and shader pipelines
public final class MetalContext {
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public let library: MTLLibrary
    
    private let logger = Logger(label: "com.heyfos.metal")
    
    // Compute pipelines
    public private(set) var laplacianPipeline: MTLComputePipelineState?
    public private(set) var tenengradPipeline: MTLComputePipelineState?
    public private(set) var ensembleFocusPipeline: MTLComputePipelineState?
    public private(set) var gaussianDownsamplePipeline: MTLComputePipelineState?
    public private(set) var gaussianBlurPipeline: MTLComputePipelineState?
    public private(set) var rgbToGrayscalePipeline: MTLComputePipelineState?
    public private(set) var weightedBlendPipeline: MTLComputePipelineState?
    
    public init() throws {
        // Get default Metal device (M2 GPU)
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalError.deviceCreationFailed
        }
        self.device = device
        
        logger.info("Metal device initialized: \(device.name)")
        
        // Create command queue
        guard let commandQueue = device.makeCommandQueue() else {
            throw MetalError.commandQueueCreationFailed
        }
        self.commandQueue = commandQueue
        
        // Load Metal library from source
        // In development, we compile shaders at runtime
        let shaderSource = try loadMetalShaderSource()
        
        guard let library = try? device.makeLibrary(source: shaderSource, options: nil) else {
            // Fallback: try loading default library
            guard let library = device.makeDefaultLibrary() else {
                throw MetalError.libraryCreationFailed
            }
            self.library = library
            try setupPipelines()
            logger.info("Metal context initialized successfully (default library)")
            return
        }
        
        self.library = library
        
        // Initialize compute pipelines
        try setupPipelines()
        
        logger.info("Metal context initialized successfully")
    }
    
    private func setupPipelines() throws {
        // Laplacian focus measure
        if let function = library.makeFunction(name: "laplacian_focus_measure") {
            laplacianPipeline = try device.makeComputePipelineState(function: function)
            logger.debug("Laplacian pipeline created")
        }
        
        // Tenengrad focus measure
        if let function = library.makeFunction(name: "tenengrad_focus_measure") {
            tenengradPipeline = try device.makeComputePipelineState(function: function)
            logger.debug("Tenengrad pipeline created")
        }
        
        // Ensemble focus measure (Laplacian + Tenengrad + Local Variance with specular suppression)
        if let function = library.makeFunction(name: "ensemble_focus_measure") {
            ensembleFocusPipeline = try device.makeComputePipelineState(function: function)
            logger.debug("Ensemble focus pipeline created")
        }
        
        // Gaussian downsample
        if let function = library.makeFunction(name: "gaussian_downsample") {
            gaussianDownsamplePipeline = try device.makeComputePipelineState(function: function)
            logger.debug("Gaussian downsample pipeline created")
        }
        
        // Gaussian blur (same size)
        if let function = library.makeFunction(name: "gaussian_blur_5x5") {
            gaussianBlurPipeline = try device.makeComputePipelineState(function: function)
            logger.debug("Gaussian blur pipeline created")
        }

        // RGB to grayscale
        if let function = library.makeFunction(name: "rgb_to_grayscale") {
            rgbToGrayscalePipeline = try device.makeComputePipelineState(function: function)
            logger.debug("RGB to grayscale pipeline created")
        }
        
        // Weighted blend
        if let function = library.makeFunction(name: "weighted_blend") {
            weightedBlendPipeline = try device.makeComputePipelineState(function: function)
            logger.debug("Weighted blend pipeline created")
        }
    }
    
    /// Create a texture from image data
    public func makeTexture(width: Int, height: Int, pixelFormat: MTLPixelFormat = .rgba32Float) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared // Shared for CPU-GPU access
        
        return device.makeTexture(descriptor: descriptor)
    }
}

public enum MetalError: Error {
    case deviceCreationFailed
    case commandQueueCreationFailed
    case libraryCreationFailed
    case pipelineCreationFailed(String)
    case textureCreationFailed
    case commandBufferCreationFailed
}
