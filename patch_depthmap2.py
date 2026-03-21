with open('Sources/HeyFoSCore/Processing/DepthMap.swift', 'r') as f:
    text = f.read()

text = text.replace(
    '''// Step 3a: Blur the focus map (Noise Reduction)
            if let blurPipeline = context.gaussianBlurPipeline {
                encoder.setComputePipelineState(blurPipeline)
                encoder.setTexture(focusMaps[i], index: 0) // Input
                encoder.setTexture(blurredFocusMap, index: 1) // Output
                encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
            } else {
                encoder.setTexture(focusMaps[i], index: 1)
            }''',
    '''// Step 3a: Pure Depth-Map (No blur to prevent halos!)
            encoder.setTexture(focusMaps[i], index: 1)'''
)

with open('Sources/HeyFoSCore/Processing/DepthMap.swift', 'w') as f:
    f.write(text)
