import re

with open('Sources/HeyFoSCore/Processing/PyBlend.swift', 'r') as f:
    text = f.read()

# 1. Update blendPyramids to pass isBase
new_blend_pyramids = '''        for level in 0..<numLevels {
            // Collect all Laplacian levels and weights for this level
            var laplacianLevels: [MTLTexture] = []
            var weightLevels: [MTLTexture] = []
            
            for i in 0..<laplacianPyramids.count {
                laplacianLevels.append(laplacianPyramids[i][level])
                weightLevels.append(weightPyramids[i][level])
            }
            
            // Blend this level
            let isBase = (level == numLevels - 1)
            let blended = try blendLevel(laplacianLevels: laplacianLevels, weightLevels: weightLevels, isBase: isBase)
            blendedPyramid.append(blended)
        }'''

text = re.sub(
    r'for level in 0..<numLevels \{.*?let blended = try blendLevel\(laplacianLevels: laplacianLevels, weightLevels: weightLevels\).*?\}',
    new_blend_pyramids,
    text,
    flags=re.DOTALL
)

# 2. Update blendLevel to accept isBase
text = text.replace(
    'private func blendLevel(laplacianLevels: [MTLTexture], weightLevels: [MTLTexture]) throws -> MTLTexture {',
    'private func blendLevel(laplacianLevels: [MTLTexture], weightLevels: [MTLTexture], isBase: Bool = false) throws -> MTLTexture {'
)

# 3. Update the shader in blendLevel
old_shader = '''        kernel void accumulate_level(
            texture2d<float, access::read> laplacian [[texture(0)]],
            texture2d<float, access::read> weight [[texture(1)]],
            texture2d<float, access::read_write> accValue [[texture(2)]],
            texture2d<float, access::read_write> accWeight [[texture(3)]],
            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= accValue.get_width() || gid.y >= accValue.get_height()) {
                return;
            }
            
            float4 lapVal = laplacian.read(gid);
            float w = max(0.0f, weight.read(gid).r);
            // w is already raised to exponent 2.5 in normalizeFocusMap.
            // Do NOT square again here — effective exponent would be ~5 → hard cutoffs → halos.
            
            // Weighted-sum accumulation (true multi-resolution blending)
            float4 curVal  = accValue.read(gid);
            float  curW    = accWeight.read(gid).r;
            accValue.write(curVal + lapVal * w, gid);
            accWeight.write(float4(curW + w, 0.0, 0.0, 1.0), gid);
        }'''

new_shader = '''        kernel void accumulate_level(
            texture2d<float, access::read> laplacian [[texture(0)]],
            texture2d<float, access::read> weight [[texture(1)]],
            texture2d<float, access::read_write> accValue [[texture(2)]],
            texture2d<float, access::read_write> accWeight [[texture(3)]],
            constant bool &isBase [[buffer(0)]],
            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= accValue.get_width() || gid.y >= accValue.get_height()) {
                return;
            }
            
            float4 lapVal = laplacian.read(gid);
            float w = max(0.0f, weight.read(gid).r);
            
            if (isBase) {
                // Weighted-sum accumulation for smooth backgrounds
                float4 curVal  = accValue.read(gid);
                float  curW    = accWeight.read(gid).r;
                accValue.write(curVal + lapVal * w, gid);
                accWeight.write(float4(curW + w, 0.0, 0.0, 1.0), gid);
            } else {
                // TRUE P-MAX: Energy-based Winner-Takes-All for sharp details!
                // Ignoring external focusMap 'w' to prevent any blur/leakage halos.
                float energy = dot(lapVal.rgb, lapVal.rgb);
                float curMaxW = accWeight.read(gid).r;
                if (energy > curMaxW) {
                    accValue.write(lapVal, gid);
                    accWeight.write(float4(energy, 0.0, 0.0, 1.0), gid);
                }
            }
        }'''

text = text.replace(old_shader, new_shader)

# 4. Pass isBase variable to encoder
old_encoder_loop = '''        for i in 0..<laplacianLevels.count {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { continue }
            encoder.setComputePipelineState(accumulatePipeline)
            encoder.setTexture(laplacianLevels[i], index: 0)
            encoder.setTexture(weightLevels[i], index: 1)
            encoder.setTexture(accValueTexture, index: 2)
            encoder.setTexture(accWeightTexture, index: 3)
            encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
            encoder.endEncoding()
        }'''

new_encoder_loop = '''        var baseFlag = isBase
        for i in 0..<laplacianLevels.count {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { continue }
            encoder.setComputePipelineState(accumulatePipeline)
            encoder.setTexture(laplacianLevels[i], index: 0)
            encoder.setTexture(weightLevels[i], index: 1)
            encoder.setTexture(accValueTexture, index: 2)
            encoder.setTexture(accWeightTexture, index: 3)
            encoder.setBytes(&baseFlag, length: MemoryLayout<Bool>.stride, index: 0)
            encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
            encoder.endEncoding()
        }'''

text = text.replace(old_encoder_loop, new_encoder_loop)

print("Modifying PyBlend...")

with open('Sources/HeyFoSCore/Processing/PyBlend.swift', 'w') as f:
    f.write(text)