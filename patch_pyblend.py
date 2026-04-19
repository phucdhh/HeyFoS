import re

with open('Sources/HeyFoSCore/Processing/PyBlend.swift', 'r') as f:
    text = f.read()

old_func_pattern = re.compile(
    r"    /// Cross-normalize weight maps so they sum to 1 at every pixel\..*?private func crossNormalizeWeights.*?return result\n    \}",
    re.DOTALL
)

new_func = """    /// Binarize focused areas (Strict Winner-Takes-All).
    /// Giai đoạn 2: Áp đặt cơ chế "Winner-Takes-All" tuyệt đối.
    private func binarizeWeights(_ weights: [MTLTexture]) throws -> [MTLTexture] {
        guard weights.count > 1 else { return weights }
        let width = weights[0].width
        let height = weights[0].height

        let shaderSource = \"\"\"
        #include <metal_stdlib>
        using namespace metal;

        kernel void compute_max_weight(
            texture2d<float, access::read>       weight [[texture(0)]],
            texture2d<float, access::read_write> maxW   [[texture(1)]],
            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= maxW.get_width() || gid.y >= maxW.get_height()) return;
            float w = max(0.0f, weight.read(gid).r);
            float currentMax = maxW.read(gid).r;
            if (w > currentMax) {
                maxW.write(float4(w, 0.0f, 0.0f, 1.0f), gid);
            }
        }

        kernel void compare_max(
            texture2d<float, access::read>  weight [[texture(0)]],
            texture2d<float, access::read>  maxW   [[texture(1)]],
            texture2d<float, access::write> output [[texture(2)]],
            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
            float w = max(0.0f, weight.read(gid).r);
            float m = maxW.read(gid).r;
            
            // Giữ lại 1.0 nếu là ảnh rõ nét nhất, ngoại trừ các điểm đen hoàn toàn
            float outW = 0.0f;
            if (m > 1e-6f && w >= m - 1e-6f) {
                outW = 1.0f;
            }
            output.write(float4(outW, outW, outW, 1.0f), gid);
        }
        \"\"\"

        let lib = try context.device.makeLibrary(source: shaderSource, options: nil)
        let computeMaxPipeline = try context.device.makeComputePipelineState(function: lib.makeFunction(name: "compute_max_weight")!)
        let comparePipeline    = try context.device.makeComputePipelineState(function: lib.makeFunction(name: "compare_max")!)

        let tg      = MTLSize(width: 16, height: 16, depth: 1)
        let tgCount = MTLSize(width: (width+15)/16, height: (height+15)/16, depth: 1)

        // Create max weight tracker texture
        let maxDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: width, height: height, mipmapped: false)
        maxDesc.usage = [.shaderRead, .shaderWrite]
        guard let maxTexture = context.device.makeTexture(descriptor: maxDesc) else {
            throw NSError(domain: "PyBlend", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create max texture"])
        }
        try clearTexture(maxTexture)

        // Pass 1: compute max per pixel
        guard let cmd1 = context.commandQueue.makeCommandBuffer() else {
            throw NSError(domain: "PyBlend", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create cmd buffer"])
        }
        for weight in weights {
            guard let enc = cmd1.makeComputeCommandEncoder() else { continue }
            enc.setComputePipelineState(computeMaxPipeline)
            enc.setTexture(weight, index: 0)
            enc.setTexture(maxTexture, index: 1)
            enc.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tg)
            enc.endEncoding()
        }
        cmd1.commit()
        cmd1.waitUntilCompleted()

        // Pass 2: binarize output based on max
        var result: [MTLTexture] = []
        guard let cmd2 = context.commandQueue.makeCommandBuffer() else {
            throw NSError(domain: "PyBlend", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create cmd buffer"])
        }
        for weight in weights {
            let outDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
            outDesc.usage = [.shaderRead, .shaderWrite]
            guard let outTex = context.device.makeTexture(descriptor: outDesc) else {
                throw NSError(domain: "PyBlend", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create output texture"])
            }
            guard let enc = cmd2.makeComputeCommandEncoder() else { continue }
            enc.setComputePipelineState(comparePipeline)
            enc.setTexture(weight, index: 0)
            enc.setTexture(maxTexture, index: 1)
            enc.setTexture(outTex, index: 2)
            enc.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tg)
            enc.endEncoding()
            result.append(outTex)
        }
        cmd2.commit()
        cmd2.waitUntilCompleted()

        return result
    }"""

new_text = old_func_pattern.sub(new_func, text)

# Now inject Phase 3 into accumulate_level
# We want to add the threshold filter to detail layers
old_accum_pattern = r"""            } else \{
                // Detail layers: Pure Winner-Takes-All on Laplacian energy. 
                // Ignores blurred 'w' focus map entirely -> ZERO HALO.
                float energy = dot\(lapVal\.rgb, lapVal\.rgb\);
                float curMaxW = accWeight\.read\(gid\)\.r;
                if \(energy > curMaxW\) \{"""
                
new_accum_replacement = """            } else {
                // Detail layers: Pure Winner-Takes-All on Laplacian energy. 
                // Giai đoạn 3: Lọc tần số không gian (High-pass threshold)
                // Lọc bỏ nhiễu nền rác. Nếu năng lượng quá bé, đây là vùng background mờ đen cần triệt tiêu.
                float energy = dot(lapVal.rgb, lapVal.rgb);
                
                if (energy < 0.0005f) {
                    return; // Dưới ngưỡng nhiễu, giữ cho laplacian tích lũy ở mức 0
                }
                
                float curMaxW = accWeight.read(gid).r;
                if (energy > curMaxW) {"""

new_text = re.sub(old_accum_pattern, new_accum_replacement, new_text)

with open('Sources/HeyFoSCore/Processing/PyBlend.swift', 'w') as f:
    f.write(new_text)

print("Done replacing.")
