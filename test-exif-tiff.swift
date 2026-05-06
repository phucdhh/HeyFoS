import Foundation
import ImageIO
import CoreGraphics

let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "test-tiff.tif") as CFURL, "public.tiff" as CFString, 1, nil)!
var props: [CFString: Any] = [
    kCGImageDestinationLossyCompressionQuality: 0.9,
    kCGImagePropertyTIFFCompression: 5
]
print("Keys before:", props.keys)
print("kCGImagePropertyTIFFCompression:", kCGImagePropertyTIFFCompression)
