import Vapor
import HeyFoSCore
import Logging
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Metal

@main
struct HeyFoSServer {
    static var jobStatuses: [String: [String: Any]] = [:]
    // Track stack metadata: stackId -> (userId, sessionId, uploadPath)
    static var stackMetadata: [String: [String: String]] = [:]

    static func main() async throws {
        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)

        let app = try await Application.make(env)

        do {
            // Configure server
            app.http.server.configuration.hostname = "0.0.0.0"  // Listen on all interfaces
            app.http.server.configuration.port = 7070
            
            // Increase upload size limits to 1GB for multiple RAW files
            app.routes.defaultMaxBodySize = ByteCount(integerLiteral: 1024 * 1024 * 1024)  // 1GB

            // CORS Middleware - Must be before routes
            let corsConfiguration = CORSMiddleware.Configuration(
                allowedOrigin: .all,
                allowedMethods: [.GET, .POST, .PUT, .OPTIONS, .DELETE, .PATCH],
                allowedHeaders: [
                    .accept, 
                    .authorization, 
                    .contentType, 
                    .origin, 
                    .xRequestedWith, 
                    .userAgent, 
                    .accessControlAllowOrigin,
                    .range,
                    HTTPHeaders.Name("X-User-ID"),
                    HTTPHeaders.Name("X-Session-ID")
                ]
            )
            app.middleware.use(CORSMiddleware(configuration: corsConfiguration))
            
            // File middleware
            app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

            // Routes
            try routes(app)

            try await app.execute()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }
}

func routes(_ app: Application) throws {
    // Health check
    app.get("health") { req async in
        return [
            "status": "ok",
            "timestamp": "\(Date().timeIntervalSince1970)",
            "version": "0.1.0"
        ]
    }

    // ── Release download page ──────────────────────────────────────────────
    // Serves release/index.html and release/*.zip at /release and /release/
    let releaseDir = DirectoryConfiguration.detect().workingDirectory
        .appending("release/")

    app.get("release") { req -> Response in
        return req.redirect(to: "/release/")
    }
    app.get("release", "") { req async throws -> Response in
        let path = releaseDir + "index.html"
        var res = req.fileio.streamFile(at: path)
        res.headers.replaceOrAdd(name: .cacheControl, value: "no-store, no-cache, must-revalidate")
        return res
    }
    app.get("release", ":filename") { req async throws -> Response in
        let filename = try req.parameters.require("filename")
        guard !filename.contains("/"), !filename.contains(".."),
              !filename.hasPrefix(".") else {
            throw Abort(.badRequest)
        }
        let path = releaseDir + filename
        var res = req.fileio.streamFile(at: path)
        res.headers.replaceOrAdd(name: .cacheControl, value: "no-store, no-cache, must-revalidate")
        // Force browser to download the file (not open it inline)
        res.headers.replaceOrAdd(
            name: .contentDisposition,
            value: "attachment; filename=\"\(filename)\""
        )
        return res
    }

    // API routes
    let api = app.grouped("api")

    // Stack management
    api.post("stacks", "init", use: initStack)
    api.post("stacks", ":stackId", "upload-file", use: uploadFile)
    api.post("stacks", "create", use: createStack)
    api.post("stacks", ":stackId", "process", use: processStack)

    // Job management
    api.get("jobs", ":jobId", "status", use: getJobStatus)
    api.get("jobs", ":jobId", "result", use: getJobResult)
    api.get("jobs", ":jobId", "preview", use: getJobPreview)
    api.get("jobs", ":jobId", "partial-preview", use: getJobPartialPreview)
}

func performProcessing(stackId: String, jobId: String, params: ProcessingParams, outputDir: URL, uploadPath: String) async throws {
    // Update job status
    HeyFoSServer.jobStatuses[jobId] = [
        "jobId": jobId,
        "status": "processing",
        "progress": 10,
        "message": "Starting processing..."
    ]

    let uploadDir = URL(fileURLWithPath: uploadPath)

    // Check if directory exists and has files
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: uploadDir.path) else {
        HeyFoSServer.jobStatuses[jobId] = [
            "jobId": jobId,
            "status": "failed",
            "progress": 0,
            "message": "Upload directory not found"
        ]
        return
    }

    let files = try fileManager.contentsOfDirectory(at: uploadDir, includingPropertiesForKeys: nil)
        .filter { ["cr2", "nef", "arw", "cr3", "dng", "tif", "tiff", "jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }

    if files.isEmpty {
        HeyFoSServer.jobStatuses[jobId] = [
            "jobId": jobId,
            "status": "failed",
            "progress": 0,
            "message": "No RAW files found"
        ]
        return
    }

    HeyFoSServer.jobStatuses[jobId] = [
        "jobId": jobId,
        "status": "processing",
        "progress": 25,
        "message": "Loading \(files.count) images...",
        "outputDir": outputDir.path,
        "totalImages": files.count,
        "currentImageIndex": 0,
        "hasPartialPreview": false
    ]

    // Create Metal context and processor
    let metalContext = try MetalContext()
    let processor = StackProcessor(metalContext: metalContext)

    // Determine focus method
    let focusMethod: FocusMeasureProcessor.Method
    switch params.depthMapAlgorithm {
    case "tenengrad":
        focusMethod = .tenengrad
    case "ensemble":
        focusMethod = .ensemble
    case "variance":
        focusMethod = .tenengrad  // legacy alias
    default:
        focusMethod = .ensemble  // ensemble is the new default
    }

    // Path for the rolling partial-preview JPEG (overwritten after each frame)
    let partialPreviewPath = outputDir.appendingPathComponent("partial_preview.jpg").path
    let outputPath = outputDir.appendingPathComponent("result.tiff").path

    try processor.processStack(
        inputDirectory: uploadDir,
        outputPath: outputPath,
        method: focusMethod,
        useAlignment: false,
        usePyramidBlending: params.blendingAlgorithm == "pyramid",
        pyramidLevels: params.pyramidLevels,
        blurRadius: params.blurRadius,
        verbose: false,
        progressHandler: { pct, message in
            let progress = Int(pct * 100)
            
            var currentIdx = HeyFoSServer.jobStatuses[jobId]?["currentImageIndex"] as? Int ?? 0
            if let slashRange = message.range(of: "/") {
                let beforeSlash = message[..<slashRange.lowerBound]
                if let spaceRange = beforeSlash.range(of: " ", options: .backwards),
                   let parsedIdx = Int(beforeSlash[spaceRange.upperBound...]) {
                    currentIdx = parsedIdx - 1
                }
            }
            
            HeyFoSServer.jobStatuses[jobId] = [
                "jobId": jobId,
                "status": "processing",
                "progress": progress,
                "message": message,
                "currentImageIndex": currentIdx,
                "totalImages": HeyFoSServer.jobStatuses[jobId]?["totalImages"] as? Int ?? files.count,
                "hasPartialPreview": HeyFoSServer.jobStatuses[jobId]?["hasPartialPreview"] as? Bool ?? false,
                "outputDir": outputDir.path
            ]
        },
        partialPreviewCallback: { imageIndex, totalImages, texture in
            // Save the partial preview JPEG (overwrites each frame for a live feed)
            try saveTextureAsJPEG(texture: texture, path: partialPreviewPath)
            HeyFoSServer.jobStatuses[jobId] = [
                "jobId": jobId,
                "status": "processing",
                "progress": 60 + (imageIndex + 1) * 20 / totalImages,
                "message": "Stacking image \(imageIndex + 1)/\(totalImages)…",
                "currentImageIndex": imageIndex,
                "totalImages": totalImages,
                "hasPartialPreview": true,
                "outputDir": outputDir.path
            ]
        }
    )

    HeyFoSServer.jobStatuses[jobId] = [
        "jobId": jobId,
        "status": "completed",
        "progress": 100,
        "message": "Processing completed successfully",
        "resultPath": outputPath,
        "outputDir": outputDir.path,
        "currentImageIndex": (HeyFoSServer.jobStatuses[jobId]?["totalImages"] as? Int ?? files.count) - 1,
        "totalImages": HeyFoSServer.jobStatuses[jobId]?["totalImages"] as? Int ?? files.count,
        "hasPartialPreview": false
    ]
}

/// Save a Metal texture as a JPEG file (quality 0.85) for partial preview delivery.
func saveTextureAsJPEG(texture: MTLTexture, path: String) throws {
    let width = texture.width
    let height = texture.height

    // Read pixel data from GPU texture (.rgba32Float)
    let bytesPerRow = width * 4 * MemoryLayout<Float>.size
    var rawFloats = [Float](repeating: 0, count: width * height * 4)
    texture.getBytes(&rawFloats,
                     bytesPerRow: bytesPerRow,
                     from: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                     size: MTLSize(width: width, height: height, depth: 1)),
                     mipmapLevel: 0)

    // Convert Float RGBA → UInt8 RGBA (clamp + gamma)
    var uint8Pixels = [UInt8](repeating: 0, count: width * height * 4)
    for i in 0..<(width * height * 4) {
        let v = rawFloats[i]
        uint8Pixels[i] = UInt8(min(max(v, 0.0), 1.0) * 255.0 + 0.5)
    }

    // Build CGImage from UInt8 data
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    guard let provider = CGDataProvider(data: Data(uint8Pixels) as CFData),
          let cgImage = CGImage(width: width, height: height,
                                bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: width * 4,
                                space: colorSpace, bitmapInfo: bitmapInfo,
                                provider: provider, decode: nil,
                                shouldInterpolate: true, intent: .defaultIntent) else {
        return
    }

    let url = URL(fileURLWithPath: path)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
    let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85]
    CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
    _ = CGImageDestinationFinalize(destination)
}

func initStack(req: Request) async throws -> InitStackResponse {
    let stackId = UUID().uuidString
    let userId = req.headers.first(name: "X-User-ID") ?? "anonymous"
    let sessionId = req.headers.first(name: "X-Session-ID") ?? UUID().uuidString

    req.logger.info("📦 Init stack: \(stackId) for user: \(userId)")

    let baseDir = URL(fileURLWithPath: "users")
    let uploadDir = baseDir
        .appendingPathComponent(userId)
        .appendingPathComponent(sessionId)
        .appendingPathComponent("upload")

    try FileManager.default.createDirectory(at: uploadDir, withIntermediateDirectories: true)

    HeyFoSServer.stackMetadata[stackId] = [
        "userId": userId,
        "sessionId": sessionId,
        "uploadPath": uploadDir.path
    ]

    return InitStackResponse(stackId: stackId, message: "Stack initialized")
}

func uploadFile(req: Request) async throws -> UploadFileResponse {
    guard let stackId = req.parameters.get("stackId") else {
        throw Abort(.badRequest, reason: "Stack ID required")
    }
    guard let metadata = HeyFoSServer.stackMetadata[stackId],
          let uploadPath = metadata["uploadPath"] else {
        throw Abort(.notFound, reason: "Stack not found")
    }

    struct SingleFile: Content { var file: File }
    let uploaded = try req.content.decode(SingleFile.self)
    let fileURL = URL(fileURLWithPath: uploadPath).appendingPathComponent(uploaded.file.filename)
    let data = Data(buffer: uploaded.file.data)
    try data.write(to: fileURL)

    req.logger.info("💾 Saved \(uploaded.file.filename) (\(data.count / 1024)KB) to stack \(stackId)")
    return UploadFileResponse(filename: uploaded.file.filename, message: "File uploaded")
}

func createStack(req: Request) async throws -> CreateStackResponse {
    // Handle multipart form data upload
    let stackId = UUID().uuidString
    
    req.logger.info("📦 Creating stack: \(stackId)")
    
    // Get userId and sessionId from request headers or body
    // Frontend should send these in headers
    let userId = req.headers.first(name: "X-User-ID") ?? "anonymous"
    let sessionId = req.headers.first(name: "X-Session-ID") ?? UUID().uuidString
    
    req.logger.info("👤 User: \(userId), Session: \(sessionId)")

    // Create directory structure: users/<userID>/<sessionID>/upload/
    let baseDir = URL(fileURLWithPath: "users")
    let userDir = baseDir.appendingPathComponent(userId)
    let sessionDir = userDir.appendingPathComponent(sessionId)
    let uploadDir = sessionDir.appendingPathComponent("upload")
    
    try FileManager.default.createDirectory(at: uploadDir, withIntermediateDirectories: true)
    req.logger.info("📁 Upload directory: \(uploadDir.path)")

    var uploadedFiles = 0
    let startTime = Date()

    // Get content type and log it
    if let contentType = req.headers.contentType {
        req.logger.info("📋 Content-Type: \(contentType)")
    }

    // Collect request body first to see size
    req.logger.info("⏳ Collecting request body...")
    let bodySize = req.body.data?.readableBytes ?? 0
    req.logger.info("📦 Body size: \(bodySize) bytes (\(bodySize / 1024 / 1024) MB)")

    // The simplest way: iterate through all decoded files
    // Vapor automatically parses multipart and provides all files with name "files"
    do {
        // When client sends multiple files with same field name "files"
        // Vapor collects them into an array
        let files: [File]
        
        do {
            // Try with array notation "files[]" first (modern FormData approach)
            let decodeStart = Date()
            req.logger.info("⏳ Attempting to decode multipart (this may take a while for large uploads)...")
            struct UploadArray: Content { 
                enum CodingKeys: String, CodingKey {
                    case files = "files[]"
                }
                var files: [File] 
            }
            files = try req.content.decode(UploadArray.self).files
            let decodeTime = Date().timeIntervalSince(decodeStart)
            req.logger.info("✅ Decoded as array with files[] notation: \(files.count) files in \(String(format: "%.2f", decodeTime))s")
        } catch {
            req.logger.warning("⚠️ Array decode (files[]) failed: \(error)")
            
            // Try plain "files" array notation (backward compatibility)
            do {
                req.logger.info("⏳ Trying plain files array...")
                struct Upload: Content { var files: [File] }
                files = try req.content.decode(Upload.self).files
                req.logger.info("✅ Decoded as plain array: \(files.count) files")
            } catch {
                req.logger.warning("⚠️ Plain array decode failed: \(error)")
                // Fall back to single file
                req.logger.info("⏳ Trying single file decode...")
                struct SingleUpload: Content { var files: File }
                let file = try req.content.decode(SingleUpload.self).files
                files = [file]
                req.logger.info("✅ Decoded as single file")
            }
        }
        
        let saveStart = Date()
        req.logger.info("💾 Starting file saves...")
        
        for (index, file) in files.enumerated() {
            let filename = file.filename
            let fileURL = uploadDir.appendingPathComponent(filename)
            
            // Write file data to disk
            let data = Data(buffer: file.data)
            try data.write(to: fileURL)
            uploadedFiles += 1
        }
        
        let saveTime = Date().timeIntervalSince(saveStart)
        let totalTime = Date().timeIntervalSince(startTime)
        req.logger.info("✅ Successfully uploaded \(uploadedFiles) files in \(String(format: "%.2f", totalTime))s (save: \(String(format: "%.2f", saveTime))s)")
        
    } catch {
        req.logger.error("❌ Upload failed: \(error)")
        req.logger.error("   Error type: \(type(of: error))")
        req.logger.error("   This usually means the multipart form data format is incorrect or timeout")
        throw Abort(.badRequest, reason: "Failed to upload files: \(error.localizedDescription)")
    }

    // Store stack metadata for later processing
    HeyFoSServer.stackMetadata[stackId] = [
        "userId": userId,
        "sessionId": sessionId,
        "uploadPath": uploadDir.path
    ]

    return CreateStackResponse(
        stackId: stackId,
        message: "Stack created successfully",
        uploadedFiles: uploadedFiles
    )
}

func processStack(req: Request) async throws -> ProcessStackResponse {
    guard let stackId = req.parameters.get("stackId") else {
        throw Abort(.badRequest, reason: "Stack ID required")
    }

    // Get stack metadata
    guard let metadata = HeyFoSServer.stackMetadata[stackId],
          let userId = metadata["userId"],
          let sessionId = metadata["sessionId"],
          let uploadPath = metadata["uploadPath"] else {
        throw Abort(.notFound, reason: "Stack not found or metadata missing")
    }

    // Parse processing parameters
    let params = try req.content.decode(ProcessingParams.self)

    // Create job
    let jobId = UUID().uuidString

    // Create output directory in session folder
    let sessionDir = URL(fileURLWithPath: uploadPath).deletingLastPathComponent()  // Remove 'upload'
    let outputDir = sessionDir.appendingPathComponent("result")
    try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

    // Start processing in background
    Task {
        do {
            try await performProcessing(stackId: stackId, jobId: jobId, params: params, outputDir: outputDir, uploadPath: uploadPath)
        } catch {
            print("Processing error: \(error)")
            HeyFoSServer.jobStatuses[jobId] = [
                "jobId": jobId,
                "status": "failed",
                "progress": 0,
                "message": "Error: \(error.localizedDescription)"
            ]
        }
    }

    return ProcessStackResponse(
        jobId: jobId,
        stackId: stackId,
        status: "processing",
        message: "Processing job started"
    )
}

func getJobStatus(req: Request) async throws -> JobStatusResponse {
    guard let jobId = req.parameters.get("jobId") else {
        throw Abort(.badRequest, reason: "Job ID required")
    }

    if let status = HeyFoSServer.jobStatuses[jobId] {
        return JobStatusResponse(
            jobId: jobId,
            status: status["status"] as? String ?? "unknown",
            progress: status["progress"] as? Int,
            message: status["message"] as? String ?? "",
            currentImageIndex: status["currentImageIndex"] as? Int,
            totalImages: status["totalImages"] as? Int,
            hasPartialPreview: status["hasPartialPreview"] as? Bool ?? false
        )
    } else {
        return JobStatusResponse(
            jobId: jobId,
            status: "not_found",
            progress: nil,
            message: "Job not found",
            currentImageIndex: nil,
            totalImages: nil,
            hasPartialPreview: false
        )
    }
}

func getJobResult(req: Request) async throws -> Response {
    guard let jobId = req.parameters.get("jobId") else {
        throw Abort(.badRequest, reason: "Job ID required")
    }

    guard let status = HeyFoSServer.jobStatuses[jobId],
          let resultPath = status["resultPath"] as? String,
          status["status"] as? String == "completed" else {
        throw Abort(.notFound, reason: "Result not found or processing not completed")
    }

    let fileURL = URL(fileURLWithPath: resultPath)
    let data = try Data(contentsOf: fileURL)

    let response = Response(status: .ok)
    response.body = .init(data: data)
    response.headers.contentType = .tiff
    response.headers.contentDisposition = .init(.attachment, filename: "heyfos_result.tiff")

    return response
}

func getJobPartialPreview(req: Request) async throws -> Response {
    guard let jobId = req.parameters.get("jobId") else {
        throw Abort(.badRequest, reason: "Job ID required")
    }

    guard let status = HeyFoSServer.jobStatuses[jobId] else {
        throw Abort(.notFound, reason: "Job not found")
    }

    // Derive partial preview path from result path or job output directory
    let partialPath: String
    if let resultPath = status["resultPath"] as? String {
        // Job completed — serve the final JPEG preview instead
        let tiffURL = URL(fileURLWithPath: resultPath)
        partialPath = tiffURL.deletingLastPathComponent().appendingPathComponent("partial_preview.jpg").path
    } else if let hasPartial = status["hasPartialPreview"] as? Bool, hasPartial {
        // Still processing — find the output directory via stackMetadata
        // The partial_preview.jpg is stored alongside where result.tiff will go.
        // We stored outputDir in jobStatuses as "outputDir".
        guard let outputDirPath = status["outputDir"] as? String else {
            throw Abort(.notFound, reason: "No partial preview available yet")
        }
        partialPath = URL(fileURLWithPath: outputDirPath).appendingPathComponent("partial_preview.jpg").path
    } else {
        throw Abort(.notFound, reason: "No partial preview available yet")
    }

    guard FileManager.default.fileExists(atPath: partialPath) else {
        throw Abort(.notFound, reason: "Partial preview not yet written")
    }

    let data = try Data(contentsOf: URL(fileURLWithPath: partialPath))
    let response = Response(status: .ok)
    response.body = .init(data: data)
    response.headers.contentType = .jpeg
    response.headers.replaceOrAdd(name: .cacheControl, value: "no-store, no-cache, must-revalidate")
    return response
}

func getJobPreview(req: Request) async throws -> Response {
    guard let jobId = req.parameters.get("jobId") else {
        throw Abort(.badRequest, reason: "Job ID required")
    }

    guard let status = HeyFoSServer.jobStatuses[jobId],
          let resultPath = status["resultPath"] as? String,
          status["status"] as? String == "completed" else {
        throw Abort(.notFound, reason: "Result not found or processing not completed")
    }

    // Generate preview JPEG from TIFF
    let tiffURL = URL(fileURLWithPath: resultPath)
    let previewPath = tiffURL.deletingPathExtension().appendingPathExtension("jpg").path
    
    // Check if preview already exists
    if !FileManager.default.fileExists(atPath: previewPath) {
        // Generate preview
        guard let imageSource = CGImageSourceCreateWithURL(tiffURL as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw Abort(.internalServerError, reason: "Failed to load TIFF image")
        }
        
        let previewURL = URL(fileURLWithPath: previewPath)
        guard let destination = CGImageDestinationCreateWithURL(previewURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw Abort(.internalServerError, reason: "Failed to create JPEG destination")
        }
        
        // JPEG with quality 0.9
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.9
        ]
        
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        
        guard CGImageDestinationFinalize(destination) else {
            throw Abort(.internalServerError, reason: "Failed to save preview JPEG")
        }
    }
    
    let data = try Data(contentsOf: URL(fileURLWithPath: previewPath))
    
    let response = Response(status: .ok)
    response.body = .init(data: data)
    response.headers.contentType = .jpeg
    
    return response
}

// MARK: - Models

struct ProcessingParams: Content {
    let depthMapAlgorithm: String // "max" or "variance"
    let blendingAlgorithm: String // "pyramid" or "linear"
    let pyramidLevels: Int
    let blurRadius: Double
}

struct InitStackResponse: Content {
    let stackId: String
    let message: String
}

struct UploadFileResponse: Content {
    let filename: String
    let message: String
}

struct CreateStackResponse: Content {
    let stackId: String
    let message: String
    let uploadedFiles: Int
}

struct ProcessStackResponse: Content {
    let jobId: String
    let stackId: String
    let status: String
    let message: String
}

struct JobStatusResponse: Content {
    let jobId: String
    let status: String
    let progress: Int?
    let message: String
    let currentImageIndex: Int?
    let totalImages: Int?
    let hasPartialPreview: Bool
}
