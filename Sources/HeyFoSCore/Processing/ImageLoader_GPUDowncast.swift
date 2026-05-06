import Foundation
import Metal
import CoreGraphics

extension ImageLoader {
    func convertTo8BitGPU(texture: MTLTexture) throws -> MTLTexture {
        // We will create a small command buffer to run 32Float -> 8Unorm
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: texture.width,
            height: texture.height,
            mipmapped: false
        )
        desc.usage = [.shaderWrite, .shaderRead]
        guard let output = metalContext.device.makeTexture(descriptor: desc) else {
            throw NSError(domain: "ImageLoader", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create 8-bit texture"])
        }
        
        let shaderSrc = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void float_to_unorm(
            texture2d<float, access::read> inTex [[texture(0)]],
            texture2d<float, access::write> outTex [[texture(1)]],
            uint2 gid [[thread_position_in_grid]]
        ) {
            if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;
            float4 color = inTex.read(gid);
            color = clamp(color, 0.0, 1.0);
            outTex.write(color, gid);
        }
        """
        
        let lib = try metalContext.device.makeLibrary(source: shaderSrc, options: MTLCompileOptions())
        let fn = lib.makeFunction(name: "float_to_unorm")!
        let pipe = try metalContext.device.makeComputePipelineState(function: fn)
        
        guard let cmd = metalContext.commandQueue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else {
            throw NSError(domain: "ImageLoader", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to make cmd"])
        }
        
        let w = pipe.threadExecutionWidth
        let h = pipe.maxTotalThreadsPerThreadgroup / w
        let tg = MTLSize(width: w, height: h, depth: 1)
        let tgc = MTLSize(width: (texture.width + w - 1) / w, height: (texture.height + h - 1) / h, depth: 1)
        
        enc.setComputePipelineState(pipe)
        enc.setTexture(texture, index: 0)
        enc.setTexture(output, index: 1)
        enc.dispatchThreadgroups(tgc, threadsPerThreadgroup: tg)
        enc.endEncoding()
        
        cmd.commit()
        cmd.waitUntilCompleted()
        
        if let err = cmd.error {
            throw err
        }
        return output
    }
}
