import Foundation
import ImageIO
import CoreGraphics

let url = URL(fileURLWithPath: "shinestacker/examples/input/img-exif/0000.tif")
var sourceMetadata: CFDictionary? = nil
var sourceImage: CGImage? = nil

if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
    sourceMetadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
    sourceImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
}

let outURL = URL(fileURLWithPath: "test-out.tif")
if let dest = CGImageDestinationCreateWithURL(outURL as CFURL, "public.tiff" as CFString, 1, nil) {
    if let cgImage = sourceImage {
       var props: [CFString: Any] = sourceMetadata as? [CFString: Any] ?? [:]
       props[kCGImagePropertyTIFFCompression] = 5
       CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
       CGImageDestinationFinalize(dest)
       print("Saved successfully")
    }
}

if let source2 = CGImageSourceCreateWithURL(outURL as CFURL, nil) {
    if let props2 = CGImageSourceCopyPropertiesAtIndex(source2, 0, nil) as? [CFString: Any] {
        print("Written Properties:", props2.keys)
    }
}
