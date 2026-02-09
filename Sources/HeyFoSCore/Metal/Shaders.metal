#include <metal_stdlib>
using namespace metal;

// MARK: - Focus Measure Kernels

/// Laplacian focus measure kernel
/// Computes the absolute Laplacian response for each pixel as a focus quality metric
kernel void laplacian_focus_measure(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    // Bounds check
    if (gid.x >= input.get_width() || gid.y >= input.get_height()) {
        return;
    }
    
    // 3x3 Laplacian kernel
    // [ 0 -1  0]
    // [-1  4 -1]
    // [ 0 -1  0]
    
    int2 pos = int2(gid);
    
    // Sample center and neighbors
    float center = input.read(uint2(pos)).r; // Use red channel as grayscale
    
    float top = input.read(uint2(clamp(pos + int2(0, -1), int2(0), int2(input.get_width()-1, input.get_height()-1)))).r;
    float bottom = input.read(uint2(clamp(pos + int2(0, 1), int2(0), int2(input.get_width()-1, input.get_height()-1)))).r;
    float left = input.read(uint2(clamp(pos + int2(-1, 0), int2(0), int2(input.get_width()-1, input.get_height()-1)))).r;
    float right = input.read(uint2(clamp(pos + int2(1, 0), int2(0), int2(input.get_width()-1, input.get_height()-1)))).r;
    
    // Compute Laplacian
    float laplacian = 4.0 * center - top - bottom - left - right;
    
    // Absolute value as focus measure
    float focus_score = abs(laplacian);
    
    // Write result
    output.write(float4(focus_score, focus_score, focus_score, 1.0), gid);
}

/// Tenengrad focus measure (Sobel-based gradient magnitude)
kernel void tenengrad_focus_measure(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= input.get_width() || gid.y >= input.get_height()) {
        return;
    }
    
    int2 pos = int2(gid);
    
    // Sobel X kernel: [-1 0 1; -2 0 2; -1 0 1]
    // Sobel Y kernel: [-1 -2 -1; 0 0 0; 1 2 1]
    
    float gx = 0.0;
    float gy = 0.0;
    
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            int2 sample_pos = clamp(pos + int2(dx, dy), int2(0), int2(input.get_width()-1, input.get_height()-1));
            float pixel = input.read(uint2(sample_pos)).r;
            
            // Sobel X weights
            float wx = float(dx) * (dy == 0 ? 2.0 : 1.0);
            gx += pixel * wx;
            
            // Sobel Y weights
            float wy = float(dy) * (dx == 0 ? 2.0 : 1.0);
            gy += pixel * wy;
        }
    }
    
    // Gradient magnitude squared (Tenengrad)
    float gradient_mag = sqrt(gx * gx + gy * gy);
    
    output.write(float4(gradient_mag, gradient_mag, gradient_mag, 1.0), gid);
}

/// Simple 5x5 Gaussian blur (no downsampling) for smoothing focus maps
kernel void gaussian_blur_5x5(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }
    
    // 5x5 Gaussian kernel weights (approximate)
    // [1  4  6  4  1]
    // [4 16 24 16  4]
    // [6 24 36 24  6] = 256 total weight
    // ...
    
    float kernel_weights[5] = {1.0, 4.0, 6.0, 4.0, 1.0};
    
    float4 sum = float4(0.0);
    float total_weight = 0.0;
    
    int2 center = int2(gid);
    
    for (int dy = -2; dy <= 2; dy++) {
        for (int dx = -2; dx <= 2; dx++) {
            int2 sample_pos = center + int2(dx, dy);
            
            // Clamp to edge
            sample_pos = clamp(sample_pos, int2(0), int2(input.get_width()-1, input.get_height()-1));
            
            float weight = kernel_weights[dx + 2] * kernel_weights[dy + 2];
            
            sum += input.read(uint2(sample_pos)) * weight;
            total_weight += weight;
        }
    }
    
    output.write(sum / total_weight, gid);
}

// MARK: - Pyramid Kernels

/// Gaussian blur for pyramid downsampling (5x5 kernel)
kernel void gaussian_downsample(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }
    
    // Input position (2x scale)
    int2 input_pos = int2(gid) * 2;
    
    // Gaussian 5x5 kernel (normalized)
    // [1  4  6  4  1]
    // [4 16 24 16  4]
    // [6 24 36 24  6]
    // [4 16 24 16  4]
    // [1  4  6  4  1] / 256
    
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

/// Convert RGB to grayscale (for focus measure preprocessing)
kernel void rgb_to_grayscale(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= input.get_width() || gid.y >= input.get_height()) {
        return;
    }
    
    float4 color = input.read(gid);
    
    // Luminance formula (ITU-R BT.709)
    float gray = 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b;
    
    output.write(float4(gray, gray, gray, 1.0), gid);
}

// MARK: - Blending Kernels

/// Weighted blend of multiple images based on focus measure
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
    
    // Normalize weights
    float total_weight = w1 + w2 + 1e-7; // Avoid division by zero
    w1 /= total_weight;
    w2 /= total_weight;
    
    // Weighted blend
    float4 result = pixel1 * w1 + pixel2 * w2;
    
    output.write(result, gid);
}
