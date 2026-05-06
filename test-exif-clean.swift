import Foundation
import ImageIO
import CoreGraphics

let url = URL(fileURLWithPath: "shinestacker/examples/input/img-exif/0000.tif")
var sourceMetadata: NSMutableDictionary?
if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
   let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
    sourceMetadata = NSMutableDictionary(dictionary: props)
    // Remove conflicting keys
    let keysToRemove = [
        kCGImagePropertyPixelWidth,
        kCGImagePropertyPixelHeight,
        kCGImagePropertyDepth,
        kCGImagePropertyColorModel,
        kCGImagePropertyOrientation
    ]
    for key in keysToRemove {
        sourceMetadata?.removeObject(forKey: key)
    }
}
print(sourceMetadata?.allKeys ?? "No metadata")
