import Foundation
import ImageIO
import CoreGraphics
import Metal
import CoreImage

let url = URL(fileURLWithPath: "shinestacker/examples/input/img-exif/0000.tif")
var sourceMetadata: [CFString: Any]? = nil
if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
    sourceMetadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
}

// Create blank CGImage similar to ImageLoader
let colorSpace = CGColorSpaceCreateDeviceRGB()
let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
var pixelData = [UInt8](repeating: 0, count: 100 * 67 * 4)
let context = CGContext(data: &pixelData,
                        width: 100,
                        height: 67,
                        bitsPerComponent: 8,
                        bytesPerRow: 100 * 4,
                        space: colorSpace,
                        bitmapInfo: bitmapInfo.rawValue)!
let cgImage = context.makeImage()!

let outURL = URL(fileURLWithPath: "test-out-2.tif")
if let dest = CGImageDestinationCreateWithURL(outURL as CFURL, "public.tiff" as CFString, 1, nil) {
    var finalProperties: [CFString: Any] = [
        kCGImageDestinationLossyCompressionQuality: 0.9,
        kCGImagePropertyTIFFCompression: 5
    ]
    if let metadata = sourceMetadata {
        for (key, value) in metadata {
            finalProperties[key] = value
        }
    }
    CGImageDestinationAddImage(dest, cgImage, finalProperties as CFDictionary)
    let finalized = CGImageDestinationFinalize(dest)
    print("Finalized:", finalized)
}

if let source2 = CGImageSourceCreateWithURL(outURL as CFURL, nil) {
    if let props2 = CGImageSourceCopyPropertiesAtIndex(source2, 0, nil) as? [CFString: Any] {
        print("Written Properties:", props2.keys)
    } else {
        print("Failed to read properties")
    }
}
