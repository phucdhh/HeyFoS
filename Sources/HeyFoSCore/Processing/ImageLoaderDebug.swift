import Foundation
import CoreGraphics
import ImageIO
import Metal
import Logging

public class ImageLoaderDebug {
    
    public static func inspectImageSource(url: URL) {
        if let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) {
            let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any]
            print("\n🔍 Image Properties for \(url.lastPathComponent):")
            
            if let depth = properties?[kCGImagePropertyDepth as String] {
                print("   Depth: \(depth)")
            }
            if let pixelWidth = properties?[kCGImagePropertyPixelWidth as String] {
                print("   Width: \(pixelWidth)")
            }
            if let pixelHeight = properties?[kCGImagePropertyPixelHeight as String] {
                print("   Height: \(pixelHeight)")
            }
            if let colorModel = properties?[kCGImagePropertyColorModel as String] {
                print("   Color Model: \(colorModel)")
            }
            
            // Check direct image creation
            if let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
                print("   CGImage Created:")
                print("     BitsPerComponent: \(cgImage.bitsPerComponent)")
                print("     BitsPerPixel: \(cgImage.bitsPerPixel)")
                print("     BytesPerRow: \(cgImage.bytesPerRow)")
                print("     BitmapInfo: \(cgImage.bitmapInfo)")
            }
        } else {
            print("❌ Failed to create CGImageSource")
        }
    }
}
