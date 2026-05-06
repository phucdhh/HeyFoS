import Foundation
import ImageIO

let url = URL(fileURLWithPath: "shinestacker/examples/input/img-exif/0000.tif")
if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
    if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
        print("Properties:", props.keys)
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
           print("EXIF:", exif)
        }
    }
}
