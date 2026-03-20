import Foundation
import Metal
import MetalPerformanceShaders
import Logging

/// Processes image stacks for focus stacking
public final class StackProcessor {
    private let metalContext: MetalContext
    private let imageLoader: ImageLoader
    private let focusProcessor: FocusMeasureProcessor
    private let logger = Logger(label: "com.heyfos.stack")
    
    public init(metalContext: MetalContext) {
        self.metalContext = metalContext
        self.imageLoader = ImageLoader(metalContext: metalContext)
        self.focusProcessor = FocusMeasureProcessor(metalContext: metalContext)
    }
    
    /// Get all image URLs (helper)
    private func getAllImageURLs(_ url: URL) throws -> [URL] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }
        
        var imageURLs: [URL] = []
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            if ["tif", "tiff", "jpg", "jpeg", "png", "cr3", "nef", "arw", "dng"].contains(ext) {
                imageURLs.append(fileURL)
            }
        }
        imageURLs.sort { $0.lastPathComponent < $1.lastPathComponent }
        return imageURLs
    }
    
    /// Load all images from directory with optional downscaling
    /// Default 3840 provides 10MP output - optimal for most users
    public func loadImagesFromDirectory(_ url: URL, maxDimension: Int = 3840) throws -> [MTLTexture] {
        let imageURLs = try getAllImageURLs(url)
        
        guard !imageURLs.isEmpty else {
            throw StackProcessingError.noImagesFound
        }
        
        logger.info("Found \(imageURLs.count) images in directory")
        
        var textures: [MTLTexture] = []
        
        for (index, imageURL) in imageURLs.enumerated() {
            logger.info("[\(index + 1)/\(imageURLs.count)] Loading: \(imageURL.lastPathComponent)")
            var texture = try imageLoader.loadImage(from: imageURL)
            
            // Downscale if image is too large to save memory
            let maxSide = max(texture.width, texture.height)
            if maxSide > maxDimension {
                let scale = Float(maxDimension) / Float(maxSide)
                let newWidth = Int(Float(texture.width) * scale)
                let newHeight = Int(Float(texture.height) * scale)
                
                logger.info("  Downscaling from \(texture.width)x\(texture.height) to \(newWidth)x\(newHeight) to save memory")
                texture = try downscaleTexture(texture, width: newWidth, height: newHeight)
            }
            
            textures.append(texture)
        }
        
        logger.info("✓ Loaded \(textures.count) images successfully")
        return textures
    }
    
    /// Compute focus measures for all images in stack
    public func computeFocusMeasures(
        for textures: [MTLTexture],
        method: FocusMeasureProcessor.Method = .laplacian
    ) throws -> [MTLTexture] {
        logger.info("Computing focus measures for \(textures.count) images...")
        
        var focusMaps: [MTLTexture] = []
        
        for (index, texture) in textures.enumerated() {
            logger.info("[\(index + 1)/\(textures.count)] Computing focus measure...")
            
            // Convert to grayscale first
            let grayTexture = try focusProcessor.convertToGrayscale(inputTexture: texture)
            
            // Compute focus measure
            let focusMap = try focusProcessor.computeFocusMeasure(
                inputTexture: grayTexture,
                method: method
            )
            
            focusMaps.append(focusMap)
        }
        
        logger.info("✓ Focus measures computed for all images")
        return focusMaps
    }
    
    /// Full pipeline: load → compute focus → alignment check → color consistency → blending → save
    public func processStack(
        inputDirectory: URL,
        outputPath: String,
        method: FocusMeasureProcessor.Method = .ensemble,
        useAlignment: Bool = true,
        usePyramidBlending: Bool = true,
        pyramidLevels: Int = 5,
        blurRadius: Double = 2.5,
        verbose: Bool = false
    ) throws {
        logger.info("=== Starting focus stacking pipeline ===")
        logger.info("Input: \(inputDirectory.path)")
        logger.info("Output: \(outputPath)")
        logger.info("Method: \(method)")
        logger.info("Alignment check: \(useAlignment)")
        logger.info("Pyramid blending: \(usePyramidBlending)")
        logger.info("Pyramid levels: \(pyramidLevels), blur radius: \(blurRadius)")
        
        // Step 1: Load images
        // Debug image source first
        if verbose {
             ImageLoaderDebug.inspectImageSource(url: try self.getAllImageURLs(inputDirectory)[0])
        }
        
        let images = try loadImagesFromDirectory(inputDirectory)
        
        // Debug first image loaded texture
        if verbose {
            let debugger = TextureDebugger(context: metalContext)
            debugger.analyzeTexture(images[0], name: "First Input Image")
        }
        
        // Step 2: Compute focus measures
        let focusMaps = try computeFocusMeasures(for: images, method: method)
        
        // Step 3: Check alignment if requested
        if useAlignment {
            logger.info("Checking image alignment...")
            let alignmentChecker = AlignmentChecker(context: metalContext)
            let alignmentResults = try alignmentChecker.analyzeAlignment(images: images)
            
            // Check if alignment correction is needed
            let maxShift = alignmentResults.map { sqrt($0.shiftX * $0.shiftX + $0.shiftY * $0.shiftY) }.max() ?? 0
            if maxShift > 2.0 {
                logger.warning("⚠️  Detected misalignment up to \(String(format: "%.1f", maxShift)) pixels")
                logger.warning("   Alignment correction not yet implemented - results may have artifacts")
            } else {
                logger.info("✓ Images appear well-aligned (max shift: \(String(format: "%.2f", maxShift)) px)")
            }
            
            // Save difference map for first vs second image
            if images.count >= 2 && verbose {
                let diffMap = try alignmentChecker.createDifferenceMap(reference: images[0], target: images[1])
                let diffPath = outputPath.replacingOccurrences(of: ".tiff", with: "_diff_0_1.tiff")
                try imageLoader.saveTexture(diffMap, to: URL(fileURLWithPath: diffPath))
                logger.info("   Saved difference map: \(diffPath)")
            }
        }
        
        // Step 3.5: Color consistency normalization
        // Corrects per-frame exposure/luminance drift from focus breathing before blending.
        logger.info("Normalizing color consistency across frames...")
        let colorNormalizer = ColorConsistencyNormalizer(context: metalContext)
        let normalizedImages = try colorNormalizer.normalize(images)
        logger.info("✓ Color consistency normalization complete")
        
        // Step 4: Perform blending
        let result: MTLTexture
        if usePyramidBlending {
            logger.info("Performing PyBlend (Pyramid Blending)...")
            let blender = PyBlend(context: metalContext, levels: pyramidLevels, blurRadius: blurRadius)
            result = try blender.blend(images: normalizedImages, focusMaps: focusMaps)
            logger.info("✓ PyBlend complete")
        } else {
            logger.info("Performing DepthMap blending...")
            let blender = DepthMap(context: metalContext)
            result = try blender.blend(images: normalizedImages, focusMaps: focusMaps, verbose: verbose)
            logger.info("✓ DepthMap blending complete")
        }
        
        // Step 5: Save result
        let outputURL = URL(fileURLWithPath: outputPath)
        try imageLoader.saveTexture(result, to: outputURL)
        
        logger.info("=== Pipeline complete! ===")
        logger.info("Result saved to: \(outputPath)")
    }
    
    /// Downscale texture using Metal bilinear sampling
    private func downscaleTexture(_ texture: MTLTexture, width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        
        guard let outputTexture = metalContext.device.makeTexture(descriptor: descriptor) else {
            throw StackProcessingError.failedToCreateTexture
        }
        
        // Use MPS for high-quality downscaling
        guard let commandBuffer = metalContext.commandQueue.makeCommandBuffer() else {
            throw StackProcessingError.failedToCreateCommandBuffer
        }
        
        let scaleFilter = MPSImageBilinearScale(device: metalContext.device)
        scaleFilter.encode(commandBuffer: commandBuffer, sourceTexture: texture, destinationTexture: outputTexture)
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        return outputTexture
    }}