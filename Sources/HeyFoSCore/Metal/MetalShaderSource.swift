import Foundation

/// Load embedded Metal shader source code
func loadMetalShaderSource() throws -> String {
    // In SPM, we need to load the .metal file as a resource
    // For now, embed the shader source directly in Swift
    return metalShaderSource
}

// Embedded Metal shader source
let metalShaderSource = """
#include <metal_stdlib>
using namespace metal;

// MARK: - Focus Measure Kernels

kernel void laplacian_focus_measure(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= input.get_width() || gid.y >= input.get_height()) {
        return;
    }
    
    int2 pos = int2(gid);
    
    float center = input.read(uint2(pos)).r;
    
    float top = input.read(uint2(clamp(pos + int2(0, -1), int2(0), int2(input.get_width()-1, input.get_height()-1)))).r;
    float bottom = input.read(uint2(clamp(pos + int2(0, 1), int2(0), int2(input.get_width()-1, input.get_height()-1)))).r;
    float left = input.read(uint2(clamp(pos + int2(-1, 0), int2(0), int2(input.get_width()-1, input.get_height()-1)))).r;
    float right = input.read(uint2(clamp(pos + int2(1, 0), int2(0), int2(input.get_width()-1, input.get_height()-1)))).r;
    
    float laplacian = 4.0 * center - top - bottom - left - right;
    float focus_score = abs(laplacian);
    
    // Amplify for better dynamic range (multiply by 1000)
    focus_score *= 1000.0;
    
    output.write(float4(focus_score, focus_score, focus_score, 1.0), gid);
}

kernel void tenengrad_focus_measure(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= input.get_width() || gid.y >= input.get_height()) {
        return;
    }
    
    int2 pos = int2(gid);
    
    float gx = 0.0;
    float gy = 0.0;
    
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            int2 sample_pos = clamp(pos + int2(dx, dy), int2(0), int2(input.get_width()-1, input.get_height()-1));
            float pixel = input.read(uint2(sample_pos)).r;
            
            float wx = float(dx) * (dy == 0 ? 2.0 : 1.0);
            gx += pixel * wx;
            
            float wy = float(dy) * (dx == 0 ? 2.0 : 1.0);
            gy += pixel * wy;
        }
    }
    
    float gradient_mag = sqrt(gx * gx + gy * gy);
    
    output.write(float4(gradient_mag, gradient_mag, gradient_mag, 1.0), gid);
}

kernel void gaussian_downsample(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }
    
    int2 input_pos = int2(gid) * 2;
    
    float weights[25] = {
        1.0/256.0,  4.0/256.0,  6.0/256.0,  4.0/256.0, 1.0/256.0,
        4.0/256.0, 16.0/256.0, 24.0/256.0, 16.0/256.0, 4.0/256.0,
        6.0/256.0, 24.0/256.0, 36.0/256.0, 24.0/256.0, 6.0/256.0,
        4.0/256.0, 16.0/256.0, 24.0/256.0, 16.0/256.0, 4.0/256.0,
        1.0/256.0,  4.0/256.0,  6.0/256.0,  4.0/256.0, 1.0/256.0
    };
    
    float4 sum = float4(0.0);
    
    for (int dy = -2; dy <= 2; dy++) {
        for (int dx = -2; dx <= 2; dx++) {
            int2 sample_pos = clamp(input_pos + int2(dx, dy), 
                                   int2(0), 
                                   int2(input.get_width()-1, input.get_height()-1));
            
            float4 pixel = input.read(uint2(sample_pos));
            float weight = weights[(dy+2)*5 + (dx+2)];
            sum += pixel * weight;
        }
    }
    
    output.write(sum, gid);
}

kernel void rgb_to_grayscale(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= input.get_width() || gid.y >= input.get_height()) {
        return;
    }
    
    float4 color = input.read(gid);
    float gray = 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b;
    
    output.write(float4(gray, gray, gray, 1.0), gid);
}

kernel void weighted_blend(
    texture2d<float, access::read> image1 [[texture(0)]],
    texture2d<float, access::read> image2 [[texture(1)]],
    texture2d<float, access::read> weight1 [[texture(2)]],
    texture2d<float, access::read> weight2 [[texture(3)]],
    texture2d<float, access::write> output [[texture(4)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }
    
    float4 pixel1 = image1.read(gid);
    float4 pixel2 = image2.read(gid);
    
    float w1 = weight1.read(gid).r;
    float w2 = weight2.read(gid).r;
    
    float total_weight = w1 + w2 + 1e-7;
    w1 /= total_weight;
    w2 /= total_weight;
    
    float4 result = pixel1 * w1 + pixel2 * w2;
    
    output.write(result, gid);
}
"""
