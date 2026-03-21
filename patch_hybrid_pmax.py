import re

with open('Sources/HeyFoSCore/Processing/PyBlend.swift', 'r') as f:
    text = f.read()

# 1. Update accumulate_level
old_acc_regex = r'kernel void accumulate_level\(.*?uint2 gid \[\[thread_position_in_grid\]\]\)\s*\{.*?\}(?=\s*kernel void finalize_level)'
new_acc = """kernel void accumulate_level(
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
                // Base layer: Soft weighted average to prevent hard seams or glow patches
                float4 curVal  = accValue.read(gid);
                float  curW    = accWeight.read(gid).r;
                accValue.write(curVal + lapVal * w, gid);
                accWeight.write(float4(curW + w, 0.0, 0.0, 1.0), gid);
            } else {
                // Detail layers: Pure Winner-Takes-All on Laplacian energy. 
                // Ignores blurred 'w' focus map entirely -> ZERO HALO.
                float energy = dot(lapVal.rgb, lapVal.rgb);
                float curMaxW = accWeight.read(gid).r;
                if (energy > curMaxW) {
                    accValue.write(lapVal, gid);
                    accWeight.write(float4(energy, 0.0, 0.0, 1.0), gid);
                }
            }
        }"""
text = re.sub(old_acc_regex, new_acc, text, flags=re.DOTALL)

# 2. Update finalize_level
old_fin_regex = r'kernel void finalize_level\(.*?uint2 gid \[\[thread_position_in_grid\]\]\)\s*\{.*?\}(?=\s*""")'
new_fin = """kernel void finalize_level(
            texture2d<float, access::read> accValue [[texture(0)]],
            texture2d<float, access::read> accWeight [[texture(1)]],
            texture2d<float, access::write> output [[texture(2)]],
            constant uint &count [[buffer(0)]],
            constant bool &isBase [[buffer(1)]],
            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
                return;
            }
            
            float4 val = accValue.read(gid);
            float  w   = accWeight.read(gid).r;
            
            if (isBase) {
                // Base layer used weighted sum, so we must normalize
                val = (w > 1e-7f) ? (val / w) : val;
            } 
            // Detail layers used Winner-Takes-All, so val is already the exact winning pixel!
            
            val.a = 1.0;
            output.write(val, gid);
        }"""
text = re.sub(old_fin_regex, new_fin, text, flags=re.DOTALL)

# 3. Pass isBase to finalizePipeline
old_fin_dispatch = r'var count = UInt32\(laplacianLevels\.count\)\s*encoder\.setBytes\(&count, length: MemoryLayout<UInt32>\.size, index: 0\)'
new_fin_dispatch = """var count = UInt32(laplacianLevels.count)
        encoder.setBytes(&count, length: MemoryLayout<UInt32>.size, index: 0)
        var baseFlagFinal = isBase
        encoder.setBytes(&baseFlagFinal, length: MemoryLayout<Bool>.stride, index: 1)"""
text = re.sub(old_fin_dispatch, new_fin_dispatch, text)

with open('Sources/HeyFoSCore/Processing/PyBlend.swift', 'w') as f:
    f.write(text)

print("Patched PyBlend to Hybrid P-Max")
