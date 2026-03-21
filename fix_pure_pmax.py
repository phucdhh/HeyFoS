import re

with open('Sources/HeyFoSCore/Processing/PyBlend.swift', 'r') as f:
    text = f.read()

# Replace accumulate_level
old_acc = '''        kernel void accumulate_level(
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

new_acc = '''        kernel void accumulate_level(
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
                // P-MAX Base layer: Hard max on overall focus weight
                float curMaxW = accWeight.read(gid).r;
                if (w > curMaxW) {
                    accValue.write(lapVal, gid);
                    accWeight.write(float4(w, 0.0, 0.0, 1.0), gid);
                }
            } else {
                // P-MAX Detail layers: Hard max on contrast energy
                float energy = dot(lapVal.rgb, lapVal.rgb);
                float curMaxW = accWeight.read(gid).r;
                if (energy > curMaxW) {
                    accValue.write(lapVal, gid);
                    accWeight.write(float4(energy, 0.0, 0.0, 1.0), gid);
                }
            }
        }'''

text = text.replace(old_acc, new_acc)

# Replace finalize_level
old_fin = '''        kernel void finalize_level(
            texture2d<float, access::read> accValue [[texture(0)]],
            texture2d<float, access::read> accWeight [[texture(1)]],
            texture2d<float, access::write> output [[texture(2)]],
            constant uint &count [[buffer(0)]],
            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
                return;
            }
            
            float4 val = accValue.read(gid);
            float  w   = accWeight.read(gid).r;
            // Normalize: divide by total weight (avoid artifacts from uncovered pixels)
            float4 result = (w > 1e-7f) ? (val / w) : val;
            result.a = 1.0;
            output.write(result, gid);
        }'''

new_fin = '''        kernel void finalize_level(
            texture2d<float, access::read> accValue [[texture(0)]],
            texture2d<float, access::read> accWeight [[texture(1)]],
            texture2d<float, access::write> output [[texture(2)]],
            constant uint &count [[buffer(0)]],
            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
                return;
            }
            
            // P-Max does no weighted averaging, so the accValue already contains the winning pixel.
            // We just output it directly! (No division by w)
            float4 val = accValue.read(gid);
            val.a = 1.0;
            output.write(val, gid);
        }'''

text = text.replace(old_fin, new_fin)

with open('Sources/HeyFoSCore/Processing/PyBlend.swift', 'w') as f:
    f.write(text)

print("Updated shaders to pure Multi-Scale P-Max")
