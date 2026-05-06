import Foundation
import CoreGraphics
import ImageIO

func extractMetadata(from url: URL) -> [CFString: Any]? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    return properties
}
