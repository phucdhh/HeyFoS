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
    public func loadImagesFromDirectory(
        _ url: URL,
        maxDimension: Int = 3840,
        perImageProgress: ((Int, Int) -> Void)? = nil
    ) throws -> [MTLTexture] {
        let imageURLs = try getAllImageURLs(url)
        guard !imageURLs.isEmpty else { throw StackProcessingError.noImagesFound }
        logger.info("Found \(imageURLs.count) images in directory")

        // Pre-allocate result slots so index ordering is preserved
        var textures   = [MTLTexture?](repeating: nil, count: imageURLs.count)
        var firstError: Error?
        var doneCount  = 0
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
                doneCount += 1
                let snapshot = doneCount
                lock.unlock()
                perImageProgress?(snapshot, imageURLs.count)
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
        method: FocusMeasureProcessor.Method = .ensemble,
        perImageProgress: ((Int, Int) -> Void)? = nil
    ) throws -> [MTLTexture] {
        logger.info("Computing focus measures for \(textures.count) images...")

        var focusMaps  = [MTLTexture?](repeating: nil, count: textures.count)
        var firstError: Error?
        var doneCount  = 0
        let lock = NSLock()

        DispatchQueue.concurrentPerform(iterations: textures.count) { index in
            do {
                let gray     = try self.focusProcessor.convertToGrayscale(inputTexture: textures[index])
                let focusMap = try self.focusProcessor.computeFocusMeasure(inputTexture: gray, method: method)
                lock.lock()
                focusMaps[index] = focusMap
                doneCount += 1
                let snapshot = doneCount
                lock.unlock()
                perImageProgress?(snapshot, textures.count)
            } catch {
                lock.lock(); if firstError == nil { firstError = error }; lock.unlock()
            }
        }

        if let err = firstError { throw err }
        let result = focusMaps.compactMap { $0 }
        logger.info("✓ Focus measures computed for all images (\(result.count)/\(textures.count))")
        return result
    }
    
    /// Full pipeline: stream each image one at a time → accumulate → save.
    /// Peak GPU memory = 1 image + 1 focus map + pyramid accumulators (~800 MB),
    /// completely independent of the number of images N.
    /// Removes the old adaptive-maxDimension downscale that produced low-res output.
    /// - Parameter partialPreviewCallback: Called after each image is stacked.
    ///   Receives (imageIndex 0-based, totalImages, partialTexture).
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
        logger.info("=== Starting focus stacking pipeline (streaming) ===")
        logger.info("Input: \(inputDirectory.path), Method: \(method), Pyramid: \(usePyramidBlending)")

        let imageURLs  = try getAllImageURLs(inputDirectory)
        let n          = imageURLs.count
        guard !imageURLs.isEmpty else { throw StackProcessingError.noImagesFound }
        logger.info("Found \(n) images")

        // Streaming pipeline: at any point only ONE full-res image + pyramid accumulators
        // (~7 levels × 2 textures) are in GPU memory. Peak ≈ 3–4 GB for 7360×4912 images,
        // well within 8 GB on any Apple Silicon Mac.
        // No adaptive downscaling — output matches input resolution exactly.
        let maxDimension = Int.max
        progressHandler?(0.01, "Preparing… (\(n) images)")

        // ── Phase 0: Pre-compute luminances from URL thumbnails ─────────────────
        // Load 64×64 CGImage thumbnails for every URL — no full-res images touched.
        // Takes ~50 ms for 127 images.
        progressHandler?(0.03, "Analysing colour balance…")
        let colorNormalizer = ColorConsistencyNormalizer(context: metalContext)
        let luminances      = colorNormalizer.precomputeLuminancesFromURLs(imageURLs)
        let referenceIdx    = n / 2
        logger.info("Colour balance pre-computed for \(n) images (reference frame: \(referenceIdx))")

        // ── Phase 1: Load + process first image, init pyramid accumulators ─────
        progressHandler?(0.07, "Initialising blender…")
        let blender      = PyBlend(context: metalContext, levels: pyramidLevels, blurRadius: blurRadius)
        let quickBlender = DepthMap(context: metalContext)

        if verbose { ImageLoaderDebug.inspectImageSource(url: imageURLs[0]) }

        let firstImage = try loadSingleImage(from: imageURLs[0], maxDimension: maxDimension)
        let scale0     = colorNormalizer.luminanceScale(frameIdx: 0, referenceIdx: referenceIdx, luminances: luminances)
        try colorNormalizer.applyScaleInPlace(firstImage, scale: scale0)

        let firstGray     = try focusProcessor.convertToGrayscale(inputTexture: firstImage)
        let firstFocusMap = try focusProcessor.computeFocusMeasure(inputTexture: firstGray, method: method)

        var accValues:  [MTLTexture]
        var accWeights: [MTLTexture]
        var dmapState:  DepthMap.DMapStreamingState? = nil

        if usePyramidBlending {
            (accValues, accWeights) = try blender.makeWTAAccumulators(forImage: firstImage)
            try blender.pMaxStreamAccumulate(image: firstImage, accValues: accValues, accWeights: accWeights)
        } else {
            (accValues, accWeights) = try blender.makeSoftBlendAccumulators(forImage: firstImage)
            var dmapS = try quickBlender.makeDMapStreamingState(width: firstImage.width, height: firstImage.height)
            try quickBlender.dmapPhase1Accumulate(focusMap: firstFocusMap, state: &dmapS)
            dmapState = dmapS
        }

        var previewTex:   MTLTexture? = nil
        var previewScore: MTLTexture? = nil

        // Show preview for image 0
        if partialPreviewCallback != nil {
            (previewTex, previewScore) = try quickBlender.blendPreviewStep(
                newImage: firstImage, newFocusMap: firstFocusMap,
                bestImage: nil, bestScore: nil)
            try partialPreviewCallback?(0, n, previewTex!)
        }
        progressHandler?(0.10, "Stacking 1/\(n)…")
        // firstImage, firstGray, firstFocusMap go out of scope below

        // ── PMax: single streaming pass (images 1…N-1) ──────────────────────
        if usePyramidBlending {
            for idx in 1..<n {
                let pct = 0.10 + Double(idx) / Double(n) * 0.80
                progressHandler?(pct, "Stacking \(idx+1)/\(n)…")

                let image = try loadSingleImage(from: imageURLs[idx], maxDimension: maxDimension)
                let scale = colorNormalizer.luminanceScale(frameIdx: idx, referenceIdx: referenceIdx, luminances: luminances)
                try colorNormalizer.applyScaleInPlace(image, scale: scale)

                let gray     = try focusProcessor.convertToGrayscale(inputTexture: image)
                let focusMap = try focusProcessor.computeFocusMeasure(inputTexture: gray, method: method)

                try blender.pMaxStreamAccumulate(image: image, accValues: accValues, accWeights: accWeights)

                if partialPreviewCallback != nil {
                    (previewTex, previewScore) = try quickBlender.blendPreviewStep(
                        newImage: image, newFocusMap: focusMap,
                        bestImage: previewTex, bestScore: previewScore)
                    try partialPreviewCallback?(idx, n, previewTex!)
                }
                // image, gray, focusMap go out of scope → GPU memory freed by ARC
            }

            progressHandler?(0.91, "Finalising…")
            let result = try blender.pMaxStreamFinalize(accValues: accValues, accWeights: accWeights)
            // Replace last WTA preview with high-quality PyBlend output
            try partialPreviewCallback?(n - 1, n, result)

            progressHandler?(0.95, "Saving result…")
            let outputURL = URL(fileURLWithPath: outputPath)
            try imageLoader.saveTexture(result, to: outputURL)

        } else {
            // ── DMap Pass 1: stream focus maps to build per-pixel max score ─────
            // Phase 1 for image 0 was already done above; continue from image 1.
            guard var dmapS = dmapState else { fatalError("dmapState should be set") }

            for idx in 1..<n {
                let pct = 0.10 + Double(idx) / Double(n) * 0.35
                progressHandler?(pct, "Analysing depth \(idx+1)/\(n)…")

                let image    = try loadSingleImage(from: imageURLs[idx], maxDimension: maxDimension)
                let gray     = try focusProcessor.convertToGrayscale(inputTexture: image)
                let focusMap = try focusProcessor.computeFocusMeasure(inputTexture: gray, method: method)

                try quickBlender.dmapPhase1Accumulate(focusMap: focusMap, state: &dmapS)

                if partialPreviewCallback != nil {
                    (previewTex, previewScore) = try quickBlender.blendPreviewStep(
                        newImage: image, newFocusMap: focusMap,
                        bestImage: previewTex, bestScore: previewScore)
                    try partialPreviewCallback?(idx, n, previewTex!)
                }
                // image, gray, focusMap freed here
            }

            // ── DMap Pass 2: re-stream images with softmax pyramid blend ─────
            // Re-load and process each image — only 1 in memory at a time.
            // DMap Pass 2 init: accumulate first image
            let firstImageP2 = try loadSingleImage(from: imageURLs[0], maxDimension: maxDimension)
            let scale0P2     = colorNormalizer.luminanceScale(frameIdx: 0, referenceIdx: referenceIdx, luminances: luminances)
            try colorNormalizer.applyScaleInPlace(firstImageP2, scale: scale0P2)
            let firstGrayP2     = try focusProcessor.convertToGrayscale(inputTexture: firstImageP2)
            let firstFocusMapP2 = try focusProcessor.computeFocusMeasure(inputTexture: firstGrayP2, method: method)
            try quickBlender.dmapPhase2Accumulate(
                image: firstImageP2, focusMap: firstFocusMapP2, state: dmapS,
                accValues: accValues, accWeights: accWeights, pyramidBlender: blender)
            progressHandler?(0.46, "Blending 1/\(n)…")

            for idx in 1..<n {
                let pct = 0.46 + Double(idx) / Double(n) * 0.44
                progressHandler?(pct, "Blending \(idx+1)/\(n)…")

                let image = try loadSingleImage(from: imageURLs[idx], maxDimension: maxDimension)
                let scale = colorNormalizer.luminanceScale(frameIdx: idx, referenceIdx: referenceIdx, luminances: luminances)
                try colorNormalizer.applyScaleInPlace(image, scale: scale)

                let gray     = try focusProcessor.convertToGrayscale(inputTexture: image)
                let focusMap = try focusProcessor.computeFocusMeasure(inputTexture: gray, method: method)

                try quickBlender.dmapPhase2Accumulate(
                    image: image, focusMap: focusMap, state: dmapS,
                    accValues: accValues, accWeights: accWeights, pyramidBlender: blender)
                // image, gray, focusMap freed here
            }

            progressHandler?(0.91, "Finalising…")
            let result = try blender.softBlendFinalize(accValues: accValues, accWeights: accWeights)
            try partialPreviewCallback?(n - 1, n, result)

            progressHandler?(0.95, "Saving result…")
            let outputURL = URL(fileURLWithPath: outputPath)
            try imageLoader.saveTexture(result, to: outputURL)
        }

        progressHandler?(1.00, "Complete!")
        logger.info("=== Pipeline complete! Result saved to: \(outputPath) ===")
    }

    /// Load a single image from URL, downscaling to maxDimension if needed.
    private func loadSingleImage(from url: URL, maxDimension: Int) throws -> MTLTexture {
        let loader  = ImageLoader(metalContext: metalContext)
        var texture = try loader.loadImage(from: url)
        let maxSide = max(texture.width, texture.height)
        if maxSide > maxDimension {
            let scale     = Float(maxDimension) / Float(maxSide)
            let newWidth  = Int(Float(texture.width)  * scale)
            let newHeight = Int(Float(texture.height) * scale)
            texture = try downscaleTexture(texture, width: newWidth, height: newHeight)
        }
        return texture
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