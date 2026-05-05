import Foundation
import CoreGraphics
import CoreImage
import Metal
import Accelerate
import Logging

/// Loads images from various formats and converts to Metal textures
public final class ImageLoader {
    private let metalContext: MetalContext
    private let rawDecoder: LibRawDecoder
    private let logger = Logger(label: "com.heyfos.imageloader")
    
    public init(metalContext: MetalContext) {
        self.metalContext = metalContext
        self.rawDecoder = LibRawDecoder()
    }
    
    /// Load image from file and convert to Metal texture
    /// - Parameter url: File URL to image (RAW, JPEG, PNG, TIFF)
    /// - Returns: Metal texture with image data
    public func loadImage(from url: URL) throws -> MTLTexture {
        logger.info("Loading image: \(url.lastPathComponent)")
        
        // Check if it's a RAW file
        if rawDecoder.isSupported(url) {
            return try loadRAW(from: url)
        } else {
            return try loadStandardImage(from: url)
        }
    }
    
    /// Load RAW image
    private func loadRAW(from url: URL) throws -> MTLTexture {
        let rawImage = try rawDecoder.decode(url)
        
        guard let texture = metalContext.makeTexture(
            width: rawImage.width,
            height: rawImage.height,
            pixelFormat: .rgba32Float
        ) else {
            throw ImageLoadError.textureCreationFailed
        }
        
        // Copy float data to texture
        let bytesPerRow = rawImage.width * rawImage.channels * MemoryLayout<Float>.size
        let region = MTLRegion(
            origin: MTLOrigin(x: 0, y: 0, z: 0),
            size: MTLSize(width: rawImage.width, height: rawImage.height, depth: 1)
        )
        
        rawImage.data.withUnsafeBytes { buffer in
            texture.replace(
                region: region,
                mipmapLevel: 0,
                withBytes: buffer.baseAddress!,
                bytesPerRow: bytesPerRow
            )
        }
        
        logger.info("RAW image loaded: \(rawImage.width)×\(rawImage.height)")
        return texture
    }
    
    /// Load standard image format (JPEG, PNG, TIFF)
    private func loadStandardImage(from url: URL) throws -> MTLTexture {
        guard let cgImage = loadCGImage(from: url) else {
            throw ImageLoadError.failedToLoadImage
        }
        
        return try createTexture(from: cgImage)
    }
    
    /// Load CGImage from file
    private func loadCGImage(from url: URL) -> CGImage? {
        if let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) {
            return CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        }
        return nil
    }
    
    /// Create Metal texture from CGImage
    private func createTexture(from cgImage: CGImage) throws -> MTLTexture {
        let width = cgImage.width
        let height = cgImage.height
        
        guard let texture = metalContext.makeTexture(
            width: width,
            height: height,
            pixelFormat: .rgba32Float
        ) else {
            throw ImageLoadError.textureCreationFailed
        }
        
        // Check BPC to determine loading strategy
        let bpc = cgImage.bitsPerComponent
        
        if bpc == 16 {
            return try createTextureFrom16Bit(from: cgImage)
        }
        
        // FALLBACK / STANDARD (8-bit)
        // We use manual UInt8 -> Float conversion to ensure [0, 1] range and avoid subnormal float issues
        // which occur when CoreGraphics draws integer data into a float context in some environments.
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // RGBA8 = 4 bytes per pixel
        let bytesPerRow = width * 4 
        var pixelData = [UInt8](repeating: 0, count: width * height * 4)
        
        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ImageLoadError.contextCreationFailed
        }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        // Convert [UInt8] -> [Float]
        var floatData = [Float](repeating: 0, count: pixelData.count)
        
        // Loop by pixel to ensure Alpha is set to 1.0 (Opaque)
        // This fixes the issue where opaque images drawn into RGBA context might have 0 alpha
        for i in stride(from: 0, to: pixelData.count, by: 4) {
            floatData[i]     = Float(pixelData[i])     / 255.0 // R
            floatData[i + 1] = Float(pixelData[i + 1]) / 255.0 // G
            floatData[i + 2] = Float(pixelData[i + 2]) / 255.0 // B
            floatData[i + 3] = 1.0                             // Force Alpha to 1.0
        }
        
        let floatBytesPerRow = width * 4 * MemoryLayout<Float>.size
        let region = MTLRegion(
            origin: MTLOrigin(x: 0, y: 0, z: 0),
            size: MTLSize(width: width, height: height, depth: 1)
        )
        
        floatData.withUnsafeBytes { buffer in
            texture.replace(
                region: region,
                mipmapLevel: 0,
                withBytes: buffer.baseAddress!,
                bytesPerRow: floatBytesPerRow
            )
        }
        
        logger.info("Standard image loaded (Manual 8-bit): \(width)×\(height)")
        return texture
    }
    
    /// Handle 16-bit TIFFs correctly by reading as UInt16 and normalizing to Float32
    private func createTextureFrom16Bit(from cgImage: CGImage) throws -> MTLTexture {
        let width = cgImage.width
        let height = cgImage.height
        
        guard let texture = metalContext.makeTexture(
            width: width,
            height: height,
            pixelFormat: .rgba32Float
        ) else {
            throw ImageLoadError.textureCreationFailed
        }
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // RGBA16 = 4 components * 2 bytes = 8 bytes per pixel
        let bytesPerRow = width * 8
        var pixelData = [UInt16](repeating: 0, count: width * height * 4)
        
        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 16,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            // Fallback to standard float loading if context fails force recursion break
            logger.warning("Failed to create UInt16 context, falling back to 8-bit")
            // Create texture manually from standard path but avoid recursion loop
            throw ImageLoadError.contextCreationFailed
        }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        // Convert [UInt16] -> [Float] normalized [0, 1] using vDSP vectorized SIMD.
        // ~20-50x faster than the equivalent per-pixel for-loop on Apple Silicon.
        var floatData = [Float](repeating: 0, count: pixelData.count)
        var scale = Float(1.0 / 65535.0)
        pixelData.withUnsafeBufferPointer { src in
            floatData.withUnsafeMutableBufferPointer { dst in
                vDSP_vfltu16(src.baseAddress!, 1, dst.baseAddress!, 1, vDSP_Length(pixelData.count))
                vDSP_vsmul(dst.baseAddress!, 1, &scale, dst.baseAddress!, 1, vDSP_Length(pixelData.count))
            }
        }
        // Force alpha = 1.0 on every 4th element (index 3, 7, 11, …)
        for i in stride(from: 3, to: floatData.count, by: 4) { floatData[i] = 1.0 }
        
        let floatBytesPerRow = width * 4 * MemoryLayout<Float>.size
        let region = MTLRegion(
            origin: MTLOrigin(x: 0, y: 0, z: 0),
            size: MTLSize(width: width, height: height, depth: 1)
        )
        
        floatData.withUnsafeBytes { buffer in
            texture.replace(
                region: region,
                mipmapLevel: 0,
                withBytes: buffer.baseAddress!,
                bytesPerRow: floatBytesPerRow
            )
        }
        
        logger.info("Loaded 16-bit image with manual conversion")
        return texture
    }
    
    /// Create a synthetic test image (checkerboard pattern)
    public func createTestImage(width: Int, height: Int, checkerSize: Int = 32) throws -> MTLTexture {
        guard let texture = metalContext.makeTexture(
            width: width,
            height: height,
            pixelFormat: .rgba32Float
        ) else {
            throw ImageLoadError.textureCreationFailed
        }
        
        var pixelData = [Float](repeating: 0, count: width * height * 4)
        
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                
                // Checkerboard pattern
                let isWhite = ((x / checkerSize) + (y / checkerSize)) % 2 == 0
                let value: Float = isWhite ? 1.0 : 0.0
                
                pixelData[index] = value     // R
                pixelData[index + 1] = value // G
                pixelData[index + 2] = value // B
                pixelData[index + 3] = 1.0   // A
            }
        }
        
        let bytesPerRow = width * 4 * MemoryLayout<Float>.size
        let region = MTLRegion(
            origin: MTLOrigin(x: 0, y: 0, z: 0),
            size: MTLSize(width: width, height: height, depth: 1)
        )
        
        pixelData.withUnsafeBytes { buffer in
            texture.replace(
                region: region,
                mipmapLevel: 0,
                withBytes: buffer.baseAddress!,
                bytesPerRow: bytesPerRow
            )
        }
        
        logger.info("Test image created: \(width)×\(height)")
        return texture
    }
    
    /// Save Metal texture to TIFF file
    public func saveTexture(_ texture: MTLTexture, to url: URL) throws {
        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 4 * MemoryLayout<Float>.size
        
        var pixelData = [Float](repeating: 0, count: width * height * 4)
        
        let region = MTLRegion(
            origin: MTLOrigin(x: 0, y: 0, z: 0),
            size: MTLSize(width: width, height: height, depth: 1)
        )
        
        pixelData.withUnsafeMutableBytes { buffer in
            texture.getBytes(
                buffer.baseAddress!,
                bytesPerRow: bytesPerRow,
                from: region,
                mipmapLevel: 0
            )
        }
        
        // Convert Float32 -> UInt8 for export (Compatibility)
        var uint8Data = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<pixelData.count {
            let val = pixelData[i]
            // Clamp [0, 1]
            let clamped = min(max(val, 0.0), 1.0)
            uint8Data[i] = UInt8(clamped * 255.0)
        }
        
        // Force Alpha to 255 (Opaque) in case it was lost
        for i in stride(from: 3, to: uint8Data.count, by: 4) {
             uint8Data[i] = 255
        }
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let uint8BytesPerRow = width * 4
        
        guard let context = CGContext(
            data: &uint8Data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: uint8BytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ImageLoadError.contextCreationFailed
        }
        
        guard let cgImage = context.makeImage() else {
            throw ImageLoadError.failedToSaveImage
        }
        
        // Save as TIFF with LZW compression
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            kUTTypeTIFF,
            1,
            nil
        ) else {
            throw ImageLoadError.failedToSaveImage
        }
        
        // Add compression properties to reduce file size
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.9,
            kCGImagePropertyTIFFCompression: 5 // LZW compression
        ]
        
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        
        guard CGImageDestinationFinalize(destination) else {
            throw ImageLoadError.failedToSaveImage
        }
        
        logger.info("Texture saved to: \(url.path)")
    }
}

public enum ImageLoadError: Error {
    case failedToLoadImage
    case textureCreationFailed
    case contextCreationFailed
    case failedToSaveImage
    case unsupportedFormat
}
