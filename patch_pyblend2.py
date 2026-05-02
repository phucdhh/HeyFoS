import re

with open('Sources/HeyFoSCore/Processing/PyBlend.swift', 'r') as f:
    text = f.read()

# 1. Update blur radius and guided filter radius
old_blur_pattern = r"let blurred = try gaussianBlur\(focusMap, radius: Float\(blurRadius\)\)\n\s*// Step B: Guided filter using the corresponding input image as guidance\.\n\s*// This edge-preserving smoothing prevents ringing artifacts at focus boundaries\.\n\s*let guided  = try guidedFilter\(blurred, guidance: images\[i\], radius: 8, eps: 0\.01\)"

new_blur = """let blurred = try gaussianBlur(focusMap, radius: 1.5) // Giai đoạn 1: Giảm blurRadius
            // Step B: Guided filter using the corresponding input image as guidance.
            // This edge-preserving smoothing prevents ringing artifacts at focus boundaries.
            let guided  = try guidedFilter(blurred, guidance: images[i], radius: 4, eps: 0.01) // Giảm radius chặn bleed"""

text = re.sub(old_blur_pattern, new_blur, text)

# 2. Update weight building logic
old_weight_pattern = r"        // Step 1.5: Binarize weights.*?print\(\"  \[3/4\] Building weight pyramids\.\.\.\"\)\n\s*var weightPyramids: \[\[MTLTexture\]\] = \[\]\n\s*for focusMap in normalizedFocusMaps \{\n\s*let weights = try buildWeightPyramid\(focusMap\)\n\s*weightPyramids\.append\(weights\)\n\s*\}"

new_weight = """        // Step 1: Build Gaussian pyramids for each image
        print("  [1/4] Building Gaussian pyramids...")
        var gaussianPyramids: [[MTLTexture]] = []
        for (i, image) in images.enumerated() {
            let pyramid = try buildGaussianPyramid(image)
            gaussianPyramids.append(pyramid)
            if i == 0 || i == images.count - 1 {
                print("    Image \\(i): pyramid levels = \\(pyramid.count)")
            }
        }
        
        // Step 2: Build Laplacian pyramids from Gaussian pyramids
        print("  [2/4] Building Laplacian pyramids...")
        var laplacianPyramids: [[MTLTexture]] = []
        for pyramid in gaussianPyramids {
            let laplacian = try buildLaplacianPyramid(gaussianPyramid: pyramid)
            laplacianPyramids.append(laplacian)
        }
        
        // Step 3: Build continuous focus pyramids and apply Per-Level WTA
        // Giai đoạn 2: Trọng số nhị phân đa tệp theo tầng tháp (Per-Level WTA Pyramid)
        print("  [3/4] Building continuous focus pyramids and applying Per-Level WTA...")
        var continuousFocusPyramids: [[MTLTexture]] = []
        for focusMap in normalizedFocusMaps {
            let focusPyr = try buildWeightPyramid(focusMap)
            continuousFocusPyramids.append(focusPyr)
        }
        
        var weightPyramids: [[MTLTexture]] = Array(repeating: [], count: images.count)
        let numLevels = continuousFocusPyramids[0].count
        for level in 0..<numLevels {
            var focusMapsAtLevel: [MTLTexture] = []
            for i in 0..<images.count {
                focusMapsAtLevel.append(continuousFocusPyramids[i][level])
            }
            // Binarize directly at this specific frequency/scale level
            let binarizedLevel = try binarizeWeights(focusMapsAtLevel)
            for i in 0..<images.count {
                weightPyramids[i].append(binarizedLevel[i])
            }
        }"""

text = re.sub(old_weight_pattern, new_weight, text, flags=re.DOTALL)

with open('Sources/HeyFoSCore/Processing/PyBlend.swift', 'w') as f:
    f.write(text)

print("Patch applied.")
