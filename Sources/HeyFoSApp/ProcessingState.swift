import Foundation
import AppKit
import HeyFoSCore

// MARK: – Settings snapshot (passed to background thread)
struct ProcessingSettings {
    let imageFiles: [URL]
    let method: ProcessingState.FocusMethod
    let usePyramidBlending: Bool
    let pyramidLevels: Int
    let blurRadius: Double
    let useAlignment: Bool
    let outputPath: String
}

// MARK: – Main state object (all Published vars updated on main thread)
final class ProcessingState: ObservableObject {

    // UI state
    @Published var imageFiles: [URL] = []
    @Published var isProcessing: Bool = false
    @Published var showResult: Bool = false
    @Published var progress: Double = 0
    @Published var progressMessage: String = "Ready"
    @Published var outputURL: URL? = nil
    @Published var resultImage: NSImage? = nil
    @Published var errorMessage: String? = nil

    // Settings
    @Published var method: FocusMethod = .ensemble
    @Published var usePyramidBlending: Bool = true
    @Published var pyramidLevels: Int = 5
    @Published var blurRadius: Double = 2.5
    @Published var useAlignment: Bool = true
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
        var seen = Set(imageFiles.map(\.path))
        for url in collected where !seen.contains(url.path) {
            imageFiles.append(url)
            seen.insert(url.path)
        }
        imageFiles.sort { $0.lastPathComponent < $1.lastPathComponent }
        errorMessage = nil
    }

    func removeImages(at offsets: IndexSet) {
        imageFiles.remove(atOffsets: offsets)
    }

    func clearAll() {
        imageFiles = []
        outputURL = nil
        resultImage = nil
        errorMessage = nil
        progress = 0
        progressMessage = "Ready"
        showResult = false
    }

    // MARK: – Processing
    func startProcessing() {
        guard !imageFiles.isEmpty, !isProcessing else { return }
        errorMessage = nil
        isProcessing = true
        progress = 0
        progressMessage = "Preparing…"

        let settings = ProcessingSettings(
            imageFiles: imageFiles,
            method: method,
            usePyramidBlending: usePyramidBlending,
            pyramidLevels: pyramidLevels,
            blurRadius: blurRadius,
            useAlignment: useAlignment,
            outputPath: outputPath
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
                    progressHandler: progressHandler
                )

                // 5. Load result image for preview
                let image = NSImage(contentsOf: outURL)
                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.outputURL = outURL
                    self.resultImage = image
                    self.progress = 1.0
                    self.progressMessage = "Complete!"
                    self.showResult = true
                }
            } catch {
                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.errorMessage = error.localizedDescription
                    self.progress = 0
                    self.progressMessage = "Error"
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
    }
}
