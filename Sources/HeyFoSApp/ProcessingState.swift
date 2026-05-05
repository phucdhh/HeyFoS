import Foundation
import AppKit
import Metal
import Accelerate
import HeyFoSCore

// MARK: – Output image record
struct OutputImageEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let methodLabel: String  // "PMax", "DMap", "Ensemble"
    let url: URL
    var nsImage: NSImage?

    var displayName: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd-HH.mm.ss"
        return "\(fmt.string(from: timestamp)) HF \(methodLabel)"
    }
}

// MARK: – Settings snapshot (passed to background thread)
struct ProcessingSettings {
    let imageFiles: [URL]
    let method: ProcessingState.FocusMethod
    let usePyramidBlending: Bool
    let pyramidLevels: Int
    let blurRadius: Double
    let useAlignment: Bool
    let outputPath: String
    let methodLabel: String
}

// MARK: – Main state object (all Published vars updated on main thread)
final class ProcessingState: ObservableObject {

    // UI state
    @Published var imageFiles: [URL] = []
    @Published var isProcessing: Bool = false
    @Published var progress: Double = 0
    @Published var progressMessage: String = "Ready"
    @Published var outputURL: URL? = nil
    @Published var errorMessage: String? = nil

    // ZereneStacker-style lists
    @Published var outputImages: [OutputImageEntry] = []
    @Published var selectedInputIndex: Int? = nil
    @Published var selectedOutputIndex: Int? = nil
    @Published var showAsAdjusted: Bool = false
    @Published var inputThumbnail: NSImage? = nil

    // Zerene-style live stacking preview
    @Published var currentStackingIndex: Int? = nil   // which input image is being stacked right now
    @Published var totalStackingImages: Int = 0
    @Published var livePreviewImage: NSImage? = nil   // intermediate result shown in right panel

    // Sheet state
    @Published var showPreferences: Bool = false

    // Settings
    @Published var method: FocusMethod = .ensemble
    @Published var usePyramidBlending: Bool = true
    @Published var pyramidLevels: Int = 8
    @Published var blurRadius: Double = 1.5
    @Published var useAlignment: Bool = false
    @Published var outputPath: String = {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        return (desktop ?? URL(fileURLWithPath: NSHomeDirectory()))
            .appendingPathComponent("heyfos_result.tiff").path
    }()

    enum FocusMethod: String, CaseIterable, Identifiable {
        case ensemble  = "Ensemble (Best)"
        case tenengrad = "Tenengrad"
        case laplacian = "Laplacian"
        var id: String { rawValue }
        var coreMethod: FocusMeasureProcessor.Method {
            switch self {
            case .ensemble:  return .ensemble
            case .tenengrad: return .tenengrad
            case .laplacian: return .laplacian
            }
        }
    }

    // MARK: – File management
    func addImages(from urls: [URL]) {
        var collected: [URL] = []
        let supportedExts = Set(["cr2","cr3","nef","arw","dng","rw2","orf","tif","tiff","jpg","jpeg","png"])
        for url in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                // Scan directory for images
                let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
                )
                if let e = enumerator {
                    for case let fileURL as URL in e {
                        if supportedExts.contains(fileURL.pathExtension.lowercased()) {
                            collected.append(fileURL)
                        }
                    }
                }
            } else if supportedExts.contains(url.pathExtension.lowercased()) {
                collected.append(url)
            }
        }
        // Merge uniquely, preserve sort order
        let hadImages = !imageFiles.isEmpty
        var seen = Set(imageFiles.map(\.path))
        for url in collected where !seen.contains(url.path) {
            imageFiles.append(url)
            seen.insert(url.path)
        }
        imageFiles.sort { $0.lastPathComponent < $1.lastPathComponent }
        errorMessage = nil
        // Auto-select first image when the list was previously empty
        if !hadImages, !imageFiles.isEmpty {
            selectedInputIndex = 0
            loadThumbnail(at: 0)
        }
    }

    func removeImages(at offsets: IndexSet) {
        imageFiles.remove(atOffsets: offsets)
    }

    // Computed label for current method settings
    var currentMethodLabel: String {
        switch (method, usePyramidBlending) {
        case (.ensemble, true): return "PMax"
        case (.laplacian, _), (.tenengrad, _): return "DMap"
        default: return "Ensemble"
        }
    }

    func clearAll() {
        imageFiles = []
        outputImages = []
        outputURL = nil
        errorMessage = nil
        progress = 0
        progressMessage = "Ready"
        selectedInputIndex = nil
        selectedOutputIndex = nil
        inputThumbnail = nil
    }

    // MARK: – Convenience stacking shortcuts
    func startStackingPMax() {
        method = .ensemble
        usePyramidBlending = true
        // useAlignment is left as-is — respects the user's Preferences setting
        startProcessing()
    }

    func startStackingDMap() {
        method = .laplacian
        usePyramidBlending = false
        // useAlignment is left as-is — respects the user's Preferences setting
        startProcessing()
    }

    // Clears only input files (not output results)
    func clearInputFiles() {
        imageFiles = []
        selectedInputIndex = nil
        inputThumbnail = nil
        errorMessage = nil
        progress = 0
        progressMessage = "Ready"
    }

    // MARK: – Thumbnail loading
    func loadThumbnail(at index: Int?) {
        guard let idx = index, idx < imageFiles.count else {
            inputThumbnail = nil
            return
        }
        let url = imageFiles[idx]
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600
            ]
            var img: NSImage? = nil
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
               let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
                img = NSImage(cgImage: cg, size: .zero)
            }
            DispatchQueue.main.async {
                if self?.selectedInputIndex == idx {
                    self?.inputThumbnail = img
                }
            }
        }
    }

    // MARK: – File picker panels (called from main thread)
    func showAddFilesPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            .image, .tiff, .jpeg, .png,
            .init(filenameExtension: "cr2")!, .init(filenameExtension: "cr3")!,
            .init(filenameExtension: "nef")!, .init(filenameExtension: "arw")!,
            .init(filenameExtension: "dng")!, .init(filenameExtension: "rw2")!,
            .init(filenameExtension: "orf")!
        ]
        panel.begin { [weak self] response in
            if response == .OK { self?.addImages(from: panel.urls) }
        }
    }

    func showAddFolderPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.begin { [weak self] response in
            if response == .OK { self?.addImages(from: panel.urls) }
        }
    }

    // MARK: – Processing
    func startProcessing() {
        guard !imageFiles.isEmpty, !isProcessing else { return }
        errorMessage = nil
        isProcessing = true
        progress = 0
        progressMessage = "Preparing…"

        // Auto-generate output path with timestamp + method if using default name
        let label = currentMethodLabel
        var resolvedOutput = outputPath
        if resolvedOutput.hasSuffix("heyfos_result.tiff") {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd-HH.mm.ss"
            let ts = fmt.string(from: Date())
            let dir = URL(fileURLWithPath: resolvedOutput).deletingLastPathComponent()
            resolvedOutput = dir.appendingPathComponent("\(ts)-HF-\(label).tiff").path
        }

        let settings = ProcessingSettings(
            imageFiles: imageFiles,
            method: method,
            usePyramidBlending: usePyramidBlending,
            pyramidLevels: pyramidLevels,
            blurRadius: blurRadius,
            useAlignment: useAlignment,
            outputPath: resolvedOutput,
            methodLabel: label
        )

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var tempDir: URL? = nil
            do {
                // 1. Build a flat temp directory with symlinks
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("HeyFoS-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                tempDir = tmp

                for url in settings.imageFiles {
                    let dest = tmp.appendingPathComponent(url.lastPathComponent)
                    try? FileManager.default.createSymbolicLink(at: dest, withDestinationURL: url)
                }

                // 2. Ensure output directory exists
                let outURL = URL(fileURLWithPath: settings.outputPath)
                try FileManager.default.createDirectory(
                    at: outURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )

                // 3. Setup core objects
                let metalContext = try MetalContext()
                let processor = StackProcessor(metalContext: metalContext)

                let progressHandler: (Double, String) -> Void = { [weak self] pct, msg in
                    DispatchQueue.main.async { self?.progress = pct; self?.progressMessage = msg }
                }

                let partialPreviewCallback: (Int, Int, MTLTexture) throws -> Void = { [weak self] idx, total, texture in
                    guard let self else { return }
                    let preview = self.textureToNSImage(texture)
                    DispatchQueue.main.async {
                        self.currentStackingIndex = idx
                        self.totalStackingImages = total
                        self.livePreviewImage = preview
                        // Auto-select the image currently being stacked so the
                        // list highlights it and the left viewer shows its thumbnail.
                        self.selectedInputIndex = idx
                    }
                }

                // 4. Run pipeline
                try processor.processStack(
                    inputDirectory: tmp,
                    outputPath: settings.outputPath,
                    method: settings.method.coreMethod,
                    useAlignment: settings.useAlignment,
                    usePyramidBlending: settings.usePyramidBlending,
                    pyramidLevels: settings.pyramidLevels,
                    blurRadius: settings.blurRadius,
                    verbose: false,
                    progressHandler: progressHandler,
                    partialPreviewCallback: partialPreviewCallback
                )

                // 5. Load result image for preview
                let image = NSImage(contentsOf: outURL)
                DispatchQueue.main.async {
                    let entry = OutputImageEntry(
                        timestamp: Date(),
                        methodLabel: settings.methodLabel,
                        url: outURL,
                        nsImage: image
                    )
                    self.outputImages.append(entry)
                    self.selectedOutputIndex = self.outputImages.count - 1
                    self.isProcessing = false
                    self.outputURL = outURL
                    self.progress = 1.0
                    self.progressMessage = "Complete! (\(entry.displayName))"
                    // Clear live preview — final result is now in outputImages
                    self.livePreviewImage = nil
                    self.currentStackingIndex = nil
                }
            } catch {
                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.errorMessage = error.localizedDescription
                    self.progress = 0
                    self.progressMessage = "Error"
                    self.livePreviewImage = nil
                    self.currentStackingIndex = nil
                }
            }
            if let tmp = tempDir { try? FileManager.default.removeItem(at: tmp) }
        }
    }

    func cancelProcessing() {
        // Note: StackProcessor doesn't support cancellation mid-flight yet.
        // We just reset the UI state; the background work finishes and its
        // result is ignored once isProcessing = false here.
        isProcessing = false
        progressMessage = "Cancelled"
        progress = 0
        livePreviewImage = nil
        currentStackingIndex = nil
    }

    // MARK: – Texture → NSImage (off-main-thread safe)
    /// Converts a .rgba32Float Metal texture to NSImage using Accelerate for fast float→UInt8.
    private func textureToNSImage(_ texture: MTLTexture) -> NSImage? {
        let w = texture.width, h = texture.height
        let count = w * h * 4
        var floats = [Float](repeating: 0, count: count)
        texture.getBytes(
            &floats,
            bytesPerRow: w * 4 * MemoryLayout<Float>.size,
            from: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                            size: MTLSize(width: w, height: h, depth: 1)),
            mipmapLevel: 0
        )
        // Clamp [0,1] and scale to [0,255] via Accelerate (vectorized)
        var lo: Float = 0, hi: Float = 1
        vDSP_vclip(floats, 1, &lo, &hi, &floats, 1, vDSP_Length(count))
        var scale: Float = 255
        vDSP_vsmul(floats, 1, &scale, &floats, 1, vDSP_Length(count))
        var bytes = [UInt8](repeating: 0, count: count)
        vDSP_vfixu8(floats, 1, &bytes, 1, vDSP_Length(count))

        let cs = CGColorSpaceCreateDeviceRGB()
        let bi = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cg = CGImage(width: w, height: h,
                               bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: w * 4, space: cs, bitmapInfo: bi,
                               provider: provider, decode: nil,
                               shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: w, height: h))
    }
}
