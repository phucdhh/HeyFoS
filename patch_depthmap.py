import re

with open('Sources/HeyFoSCore/Processing/DepthMap.swift', 'r') as f:
    text = f.read()

# Remove the blur pipeline pass inside DepthMap.swift to prevent halos there too
target_block = r'// Step 3a: Blur the focus map \(Noise Reduction\)\s*if let blurPipeline = context\.gaussianBlurPipeline \{.*?\}\s*else\s*\{.*?\encoder\.setTexture\(focusMaps\[i\], index: 1\).*?\}'

replacement_block = """// Step 3a: NO BLUR for Focus Map! Blurring causes halo bleeding!
            // We pass the raw focus map directly.
            encoder.setTexture(focusMaps[i], index: 1)"""

text = re.sub(target_block, replacement_block, text, flags=re.DOTALL)

with open('Sources/HeyFoSCore/Processing/DepthMap.swift', 'w') as f:
    f.write(text)

print("DepthMap halos removed")
