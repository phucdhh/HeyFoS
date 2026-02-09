import Foundation
import Metal
import MetalKit

/// Debug helper to inspect texture values
public class TextureDebugger {
    private let context: MetalContext
    
    public init(context: MetalContext) {
        self.context = context
    }
    
    public func analyzeTexture(_ texture: MTLTexture, name: String) {
        let width = texture.width
        let height = texture.height
        let count = width * height * 4
        var data = [Float](repeating: 0, count: count)
        
        let region = MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: width, height: height, depth: 1))
        let bytesPerRow = width * 4 * MemoryLayout<Float>.size
        
        texture.getBytes(&data, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)
        
        var minVal: Float = .greatestFiniteMagnitude
        var maxVal: Float = -.greatestFiniteMagnitude
        var avgVal: Float = 0
        var zeroCount = 0
        
        for i in stride(from: 0, to: count, by: 4) {
            let r = data[i]
            if r < minVal { minVal = r }
            if r > maxVal { maxVal = r }
            avgVal += r
            if abs(r) < 0.000001 { zeroCount += 1 }
        }
        
        avgVal /= Float(width * height)
        
        print("🔍 Texture Analysis [\(name)]:")
        print("   Size: \(width)x\(height)")
        print("   Range: [\(minVal), \(maxVal)]")
        print("   Average: \(avgVal)")
        print("   Zero pixels: \(zeroCount) (\(Float(zeroCount)/Float(width*height)*100.0)%)")
    }
}
