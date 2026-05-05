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
    
    /// Load all images from directory with optional downscaling.
    /// Images are decoded in parallel (one thread per logical CPU / 2, capped at 4)
    /// to exploit the M-series efficiency cores for I/O-bound work.
    /// Default 3840 provides 10MP output — optimal for most users.
    public func loadImagesFromDirectory(_ url: URL, maxDimension: Int = 3840) throws -> [MTLTexture] {
        let imageURLs = try getAllImageURLs(url)
        guard !imageURLs.isEmpty else { throw StackProcessingError.noImagesFound }
        logger.info("Found \(imageURLs.count) images in directory")

        // Pre-allocate result slots so index ordering is preserved
        var textures   = [MTLTexture?](repeating: nil, count: imageURLs.count)
        var firstError: Error?
        let lock       = NSLock()

        // Each ImageLoader uses its own LibRaw processor handle (thread-safe)
        // and MTLDevice.makeTexture is documented thread-safe on Apple Silicon.
        let parallelism = max(1, min(4, ProcessInfo.processInfo.processorCount / 2))

        DispatchQueue.concurrentPerform(iterations: imageURLs.count) { index in
            let url = imageURLs[index]
            do {
                let loader  = ImageLoader(metalContext: self.metalContext)   // fresh per thread
                var texture = try loader.loadImage(from: url)

                let maxSide = max(texture.width, texture.height)
                if maxSide > maxDimension {
                    let scale    = Float(maxDimension) / Float(maxSide)
                    let newWidth = Int(Float(texture.width)  * scale)
                    let newHeight = Int(Float(texture.height) * scale)
                    texture = try self.downscaleTexture(texture, width: newWidth, height: newHeight)
                }
                lock.lock()
                textures[index] = texture
                lock.unlock()
            } catch {
                lock.lock()
                if firstError == nil { firstError = error }
                lock.unlock()
            }
        }

        if let err = firstError { throw err }

        let result = textures.compactMap { $0 }
        logger.info("✓ Loaded \(result.count) images (parallelism: \(parallelism))")
        return result
    }
    
    /// Compute focus measures for all images in stack.
    /// Encodes grayscale + focus command buffers concurrently across CPU cores.
    /// FocusMeasureProcessor holds only read-only pipeline states → thread-safe to share.
    /// Within each image, grayscale is committed before focus on the same thread,
    /// so Metal queue ordering guarantees correct per-image GPU execution order.
    public func computeFocusMeasures(
        for textures: [MTLTexture],
        method: FocusMeasureProcessor.Method = .ensemble
    ) throws -> [MTLTexture] {
        logger.info("Computing focus measures for \(textures.count) images...")

        var focusMaps  = [MTLTexture?](repeating: nil, count: textures.count)
        var firstError: Error?
        let lock = NSLock()

        DispatchQueue.concurrentPerform(iterations: textures.count) { index in
            do {
                let gray     = try self.focusProcessor.convertToGrayscale(inputTexture: textures[index])
                let focusMap = try self.focusProcessor.computeFocusMeasure(inputTexture: gray, method: method)
                lock.lock(); focusMaps[index] = focusMap; lock.unlock()
            } catch {
                lock.lock(); if firstError == nil { firstError = error }; lock.unlock()
            }
        }

        if let err = firstError { throw err }
        let result = focusMaps.compactMap { $0 }
        logger.info("✓ Focus measures computed for all images (\(result.count)/\(textures.count))")
        return result
    }
    
    /// Full pipeline: load → compute focus → alignment check → color consistency → blending → save
    /// - Parameter partialPreviewCallback: Called after each image is incrementally stacked.
    ///   Receives (imageIndex 0-based, totalImages, partialTexture).
    ///   Use this to save live preview frames (Zerene-style progressive reveal).
    public func processStack(
        inputDirectory: URL,
        outputPath: String,
        method: FocusMeasureProcessor.Method = .ensemble,
        useAlignment: Bool = true,
        usePyramidBlending: Bool = true,
        pyramidLevels: Int = 6,
        blurRadius: Double = 1.5,
        verbose: Bool = false,
        progressHandler: ((Double, String) -> Void)? = nil,
        partialPreviewCallback: ((Int, Int, MTLTexture) throws -> Void)? = nil
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
        
        progressHandler?(0.05, "Loading images…")
        let images = try loadImagesFromDirectory(inputDirectory)
        
        // Debug first image loaded texture
        if verbose {
            let debugger = TextureDebugger(context: metalContext)
            debugger.analyzeTexture(images[0], name: "First Input Image")
        }
        
        // Step 2: Compute focus measures
        progressHandler?(0.20, "Computing focus measures…")
        let focusMaps = try computeFocusMeasures(for: images, method: method)
        
        // Step 3: Alignment check + correction
        var alignedImages = images
        if useAlignment {
            progressHandler?(0.40, "Checking alignment…")
            logger.info("Checking image alignment...")
            let aligner = AlignmentChecker(context: metalContext)
            let alignmentResults = try aligner.analyzeAlignment(images: images)

            let maxShift = alignmentResults.map { sqrtf($0.shiftX * $0.shiftX + $0.shiftY * $0.shiftY) }.max() ?? 0
            if maxShift > 0.5 {
                logger.info("⚠️  Detected misalignment up to \(String(format: "%.1f", maxShift)) px — correcting...")
                alignedImages = try aligner.correctAlignment(images: images, threshold: 0.5)
                logger.info("✓ Alignment correction applied")
            } else {
                logger.info("✓ Images well-aligned (max shift: \(String(format: "%.2f", maxShift)) px)")
            }

            if images.count >= 2 && verbose {
                let diffMap  = try aligner.createDifferenceMap(reference: images[0], target: images[1])
                let diffPath = outputPath.replacingOccurrences(of: ".tiff", with: "_diff_0_1.tiff")
                try imageLoader.saveTexture(diffMap, to: URL(fileURLWithPath: diffPath))
                logger.info("   Saved difference map: \(diffPath)")
            }
        }
        
        // Step 3.5: Color consistency normalization
        // Corrects per-frame exposure/luminance drift from focus breathing before blending.
        progressHandler?(0.55, "Normalizing color consistency…")
        logger.info("Normalizing color consistency across frames...")
        let colorNormalizer = ColorConsistencyNormalizer(context: metalContext)
        let normalizedImages = try colorNormalizer.normalize(alignedImages)
        logger.info("✓ Color consistency normalization complete")
        
        // Steps 3.8 + 4 unified: PyBlend streaming with per-image WTA preview.
        // Both passes are merged into one loop — each image is processed once through
        // the Laplacian pyramid accumulator (final-blend quality) while the fast WTA
        // blendPreviewStep updates the UI after every image for a smooth progressive reveal.
        // The final PyBlend result replaces the WTA preview exactly once at the end.
        // Algorithm and output are identical to the previous two-pass approach.
        progressHandler?(0.60, "Blending 0/\(normalizedImages.count)…")
        let result: MTLTexture
        if usePyramidBlending {
            logger.info("Performing PyBlend (Pyramid Blending)...")
            let blender     = PyBlend(context: metalContext, levels: pyramidLevels, blurRadius: blurRadius)
            let quickBlender = DepthMap(context: metalContext)
            var previewTex: MTLTexture? = nil
            var scoreTex:   MTLTexture? = nil
            result = try blender.blend(
                images: normalizedImages,
                focusMaps: focusMaps,
                perImageCallback: { i, total in
                    let pct = 0.60 + Double(i + 1) / Double(total) * 0.35
                    progressHandler?(pct, "Blending \(i + 1)/\(total)…")
                    if let callback = partialPreviewCallback {
                        (previewTex, scoreTex) = try quickBlender.blendPreviewStep(
                            newImage:    normalizedImages[i],
                            newFocusMap: focusMaps[i],
                            bestImage:   previewTex,
                            bestScore:   scoreTex
                        )
                        try callback(i, total, previewTex!)
                    }
                }
            )
            // Show the final high-quality PyBlend result once — replaces the last WTA preview
            try partialPreviewCallback?(normalizedImages.count - 1, normalizedImages.count, result)
            logger.info("✓ PyBlend complete")
        } else {
            logger.info("Performing DepthMap blending...")
            let blender = DepthMap(context: metalContext)
            result = try blender.blend(
                images: normalizedImages,
                focusMaps: focusMaps,
                progressHandler: { pct, msg in
                    // Scale DMap's 0→1 range into the 60%→95% pipeline window
                    progressHandler?(0.60 + pct * 0.35, msg)
                },
                partialPreviewCallback: { i, total, tex in
                    try partialPreviewCallback?(i, total, tex)
                }
            )
            logger.info("✓ DepthMap blending complete")
        }
        
        // Step 5: Save result
        progressHandler?(0.95, "Saving result…")
        let outputURL = URL(fileURLWithPath: outputPath)
        try imageLoader.saveTexture(result, to: outputURL)
        
        progressHandler?(1.00, "Complete!")
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