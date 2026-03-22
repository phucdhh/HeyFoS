import re

def update_file():
    with open("Sources/HeyFoSCore/Processing/ImageLoader.swift", "r") as f:
        text = f.read()

    # Add baseImageProperties
    prop_decl = """    private let logger = Logger(label: "com.heyfos.imageloader")
    
    /// Stored metadata from the first loaded image to apply to the output
    public var baseImageProperties: CFDictionary?
"""
    text = text.replace('    private let logger = Logger(label: "com.heyfos.imageloader")', prop_decl)

    # Update loadCGImage
    old_loadCG = """    private func loadCGImage(from url: URL) -> CGImage? {
        if let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) {
            return CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        }
        return nil
    }"""
    new_loadCG = """    private func loadCGImage(from url: URL) -> CGImage? {
        if let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) {
            // Capture metadata from the first loaded image
            if self.baseImageProperties == nil {
                self.baseImageProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil)
            }
            return CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        }
        return nil
    }"""
    text = text.replace(old_loadCG, new_loadCG)

    # Update saveTexture
    old_save = """        // Add compression properties to reduce file size
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.9,
            kCGImagePropertyTIFFCompression: 5 // LZW compression
        ]
        
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)"""

    new_save = """        // Prepare metadata dictionary combining base metadata with our settings
        var properties: [CFString: Any] = [:]
        
        if let base = self.baseImageProperties as? [CFString: Any] {
            properties = base
            // Strip dimensions since we may have cropped the image during alignment
            properties.removeValue(forKey: kCGImagePropertyPixelWidth)
            properties.removeValue(forKey: kCGImagePropertyPixelHeight)
            properties.removeValue(forKey: kCGImagePropertyOrientation)
        }
        
        properties[kCGImageDestinationLossyCompressionQuality] = 0.9
        properties[kCGImagePropertyTIFFCompression] = 5 // LZW compression
        
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)"""
    text = text.replace(old_save, new_save)

    with open("Sources/HeyFoSCore/Processing/ImageLoader.swift", "w") as f:
        f.write(text)

    print("Patched ImageLoader.swift")

if __name__ == "__main__":
    update_file()
