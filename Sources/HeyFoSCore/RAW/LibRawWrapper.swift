import Foundation
import Logging
import CLibRaw

/// Wrapper for LibRaw library to decode RAW image files
public final class LibRawDecoder {
    private let logger = Logger(label: "com.heyfos.raw")
    
    public init() {}
    
    /// Decode RAW file to linear RGB float32 array
    /// - Parameters:
    ///   - url: File URL to RAW image
    ///   - linearize: If true, convert to linear space (no gamma curve)
    /// - Returns: Decoded image data with metadata
    public func decode(_ url: URL, linearize: Bool = true) throws -> RawImage {
        logger.info("Decoding RAW file: \(url.lastPathComponent)")
        
        let processor = heyfos_libraw_init()
        guard processor != nil else {
            throw RawDecodingError.decodingFailed("Failed to initialize LibRaw")
        }
        defer { heyfos_libraw_cleanup(processor) }
        
        // Open file
        let path = url.path
        var result = heyfos_libraw_open_file(processor, path)
        guard result == 0 else {
            let error = String(cString: heyfos_libraw_get_error(processor))
            throw RawDecodingError.decodingFailed("Failed to open file: \(error)")
        }
        
        // Unpack RAW data
        result = heyfos_libraw_unpack(processor)
        guard result == 0 else {
            let error = String(cString: heyfos_libraw_get_error(processor))
            throw RawDecodingError.decodingFailed("Failed to unpack: \(error)")
        }
        
        // Process to linear RGB
        result = heyfos_libraw_process_linear(processor)
        guard result == 0 else {
            let error = String(cString: heyfos_libraw_get_error(processor))
            throw RawDecodingError.decodingFailed("Failed to process: \(error)")
        }
        
        // Get image data
        guard let imageData = heyfos_libraw_get_image_data(processor) else {
            throw RawDecodingError.decodingFailed("Failed to get image data")
        }
        defer { heyfos_libraw_free_image_data(imageData) }
        
        // Copy data to Swift array
        let dataPtr = imageData.pointee.data
        let dataSize = Int(imageData.pointee.data_size) / MemoryLayout<Float>.size
        let data = Array(UnsafeBufferPointer(start: dataPtr, count: dataSize))
        
        // Get metadata
        var metadata = ImageMetadata()
        if let meta = heyfos_libraw_get_metadata(processor) {
            defer { heyfos_libraw_free_metadata(meta) }
            
            metadata = ImageMetadata(
                make: String(cString: &meta.pointee.make.0),
                model: String(cString: &meta.pointee.model.0),
                iso: Int(meta.pointee.iso_speed),
                shutterSpeed: Double(meta.pointee.shutter_speed),
                aperture: Double(meta.pointee.aperture),
                focalLength: Double(meta.pointee.focal_length),
                whiteBalance: (
                    r: meta.pointee.wb_r,
                    g: meta.pointee.wb_g,
                    b: meta.pointee.wb_b
                )
            )
        }
        
        logger.info("RAW decoded: \(imageData.pointee.width)×\(imageData.pointee.height), \(imageData.pointee.channels) channels")
        
        return RawImage(
            width: Int(imageData.pointee.width),
            height: Int(imageData.pointee.height),
            channels: Int(imageData.pointee.channels),
            data: data,
            metadata: metadata
        )
    }
    
    /// Check if file is a supported RAW format
    public func isSupported(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        let supportedFormats = ["cr3", "cr2", "nef", "arw", "dng", "raf", "orf", "rw2"]
        return supportedFormats.contains(ext)
    }
}

/// Decoded RAW image data
public struct RawImage {
    public let width: Int
    public let height: Int
    public let channels: Int // Usually 3 (RGB) or 4 (RGBA)
    public let data: [Float] // Linear RGB float32 data
    public let metadata: ImageMetadata
    
    public init(width: Int, height: Int, channels: Int, data: [Float], metadata: ImageMetadata) {
        self.width = width
        self.height = height
        self.channels = channels
        self.data = data
        self.metadata = metadata
    }
}

public struct ImageMetadata {
    public let make: String?
    public let model: String?
    public let iso: Int?
    public let shutterSpeed: Double?
    public let aperture: Double?
    public let focalLength: Double?
    public let whiteBalance: (r: Float, g: Float, b: Float)?
    
    public init(
        make: String? = nil,
        model: String? = nil,
        iso: Int? = nil,
        shutterSpeed: Double? = nil,
        aperture: Double? = nil,
        focalLength: Double? = nil,
        whiteBalance: (r: Float, g: Float, b: Float)? = nil
    ) {
        self.make = make
        self.model = model
        self.iso = iso
        self.shutterSpeed = shutterSpeed
        self.aperture = aperture
        self.focalLength = focalLength
        self.whiteBalance = whiteBalance
    }
}

public enum RawDecodingError: Error {
    case fileNotFound
    case unsupportedFormat
    case decodingFailed(String)
    case notImplemented(String)
}
