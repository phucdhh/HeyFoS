import Foundation
import Metal
import Logging

public class DepthMap {
    private let context: MetalContext
    private let logger = Logger(label: "com.heyfos.depthmap")

    // ── Metal shader source (compiled ONCE at init) ───────────────────────────
    private static let shaderSrc = """
    #include <metal_stdlib>
    using namespace metal;

    // Initialize winner-takes-all maps: maxScore = -1, maxIndex = 0
    kernel void init_maps(texture2d<float, access::write> maxScore [[texture(0)]],
                          texture2d<float, access::write> maxIndex [[texture(1)]],
                          uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= maxScore.get_width() || gid.y >= maxScore.get_height()) return;
        maxScore.write(float4(-1.0), gid);
        maxIndex.write(float4(0.0), gid);
    }

    // Zero a single-channel or multi-channel texture
    kernel void zero_tex(texture2d<float, access::write> tex [[texture(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= tex.get_width() || gid.y >= tex.get_height()) return;
        tex.write(float4(0.0), gid);
    }

    // Separable Gaussian blur — horizontal pass (R32Float)
    kernel void blur_h(texture2d<float, access::read>  src   [[texture(0)]],
                       texture2d<float, access::write> dst   [[texture(1)]],
                       constant float               &sigma   [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
        uint W = src.get_width(), H = src.get_height();
        if (gid.x >= W || gid.y >= H) return;
        int r = max(1, int(sigma * 2.5 + 0.5));
        float s2 = 2.0 * sigma * sigma;
        float vsum = 0.0, wsum = 0.0;
        for (int dx = -r; dx <= r; dx++) {
            int x = clamp(int(gid.x) + dx, 0, int(W) - 1);
            float w = exp(-float(dx * dx) / s2);
            vsum += src.read(uint2(x, gid.y)).r * w;
            wsum += w;
        }
        dst.write(float4(vsum / wsum, 0.0, 0.0, 1.0), gid);
    }

    // Separable Gaussian blur — vertical pass (R32Float)
    kernel void blur_v(texture2d<float, access::read>  src   [[texture(0)]],
                       texture2d<float, access::write> dst   [[texture(1)]],
                       constant float               &sigma   [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
        uint W = src.get_width(), H = src.get_height();
        if (gid.x >= W || gid.y >= H) return;
        int r = max(1, int(sigma * 2.5 + 0.5));
        float s2 = 2.0 * sigma * sigma;
        float vsum = 0.0, wsum = 0.0;
        for (int dy = -r; dy <= r; dy++) {
            int y = clamp(int(gid.y) + dy, 0, int(H) - 1);
            float w = exp(-float(dy * dy) / s2);
            vsum += src.read(uint2(gid.x, y)).r * w;
            wsum += w;
        }
        dst.write(float4(vsum / wsum, 0.0, 0.0, 1.0), gid);
    }

    // Update winner-takes-all maps
    kernel void update_max(texture2d<float, access::read>  focus      [[texture(0)]],
                           texture2d<float, access::read>  maxScoreIn [[texture(1)]],
                           texture2d<float, access::write> maxScoreOut[[texture(2)]],
                           texture2d<float, access::read>  maxIndexIn [[texture(3)]],
                           texture2d<float, access::write> maxIndexOut[[texture(4)]],
                           constant uint &index [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= focus.get_width() || gid.y >= focus.get_height()) return;
        float score = focus.read(gid).r;
        float best  = maxScoreIn.read(gid).r;
        if (score > best) {
            maxScoreOut.write(float4(score), gid);
            maxIndexOut.write(float4(float(index)), gid);
        } else {
            maxScoreOut.write(float4(best), gid);
            maxIndexOut.write(maxIndexIn.read(gid), gid);
        }
    }

    // Generate hard binary mask for image at targetIndex
    kernel void create_mask(texture2d<float, access::read>  maxIndex [[texture(0)]],
                            texture2d<float, access::write> mask     [[texture(1)]],
                            constant uint &targetIndex [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= maxIndex.get_width() || gid.y >= maxIndex.get_height()) return;
        float idx = maxIndex.read(gid).r;
        float val = (abs(idx - float(targetIndex)) < 0.1) ? 1.0 : 0.0;
        mask.write(float4(val), gid);
    }

    // Weighted accumulate
    kernel void accum_blend(texture2d<float, access::read>  image      [[texture(0)]],
                            texture2d<float, access::read>  mask       [[texture(1)]],
                            texture2d<float, access::read>  resultIn   [[texture(2)]],
                            texture2d<float, access::write> resultOut  [[texture(3)]],
                            texture2d<float, access::read>  weightIn   [[texture(4)]],
                            texture2d<float, access::write> weightOut  [[texture(5)]],
                            uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= image.get_width() || gid.y >= image.get_height()) return;
        float w   = mask.read(gid).r;
        float4 c  = image.read(gid);
        resultOut.write(resultIn.read(gid) + c * w, gid);
        weightOut.write(float4(weightIn.read(gid).r + w), gid);
    }

    // Normalize accumulated result
    kernel void finalize_blend(texture2d<float, access::read>  resultIn [[texture(0)]],
                               texture2d<float, access::read>  weightSum[[texture(1)]],
                               texture2d<float, access::write> finalOut [[texture(2)]],
                               uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= resultIn.get_width() || gid.y >= resultIn.get_height()) return;
        float sum    = weightSum.read(gid).r;
        float4 color = resultIn.read(gid);
        if (sum > 0.0001) color = color / sum;
        finalOut.write(color, gid);
    }

    // Streaming WTA for O(N) incremental preview.
    // For each pixel keeps whichever image has the highest focus score seen so far.
    kernel void preview_step(
        texture2d<float, access::read>       newImage  [[texture(0)]],
        texture2d<float, access::read>       newFocus  [[texture(1)]],
        texture2d<float, access::read_write> bestImage [[texture(2)]],
        texture2d<float, access::read_write> bestScore [[texture(3)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= bestImage.get_width() || gid.y >= bestImage.get_height()) return;
        float newScore = newFocus.read(gid).r;
        float curScore = bestScore.read(gid).r;
        if (newScore > curScore) {
            bestImage.write(newImage.read(gid), gid);
            bestScore.write(float4(newScore), gid);
        }
    }
    """

    // ── Pipeline states cached at init — never recompiled ────────────────────
    private let initPipe:        MTLComputePipelineState
    private let zeroTexPipe:     MTLComputePipelineState
    private let blurHPipe:       MTLComputePipelineState
    private let blurVPipe:       MTLComputePipelineState
    private let updatePipe:      MTLComputePipelineState
    private let maskPipe:        MTLComputePipelineState
    private let accumPipe:       MTLComputePipelineState
    private let finalizePipe:    MTLComputePipelineState
    private let previewStepPipe: MTLComputePipelineState

    public init(context: MetalContext) {
        self.context = context
        let lib          = try! context.device.makeLibrary(source: DepthMap.shaderSrc, options: nil)
        initPipe        = try! context.device.makeComputePipelineState(function: lib.makeFunction(name: "init_maps")!)
        zeroTexPipe     = try! context.device.makeComputePipelineState(function: lib.makeFunction(name: "zero_tex")!)
        blurHPipe       = try! context.device.makeComputePipelineState(function: lib.makeFunction(name: "blur_h")!)
        blurVPipe       = try! context.device.makeComputePipelineState(function: lib.makeFunction(name: "blur_v")!)
        updatePipe      = try! context.device.makeComputePipelineState(function: lib.makeFunction(name: "update_max")!)
        maskPipe        = try! context.device.makeComputePipelineState(function: lib.makeFunction(name: "create_mask")!)
        accumPipe       = try! context.device.makeComputePipelineState(function: lib.makeFunction(name: "accum_blend")!)
        finalizePipe    = try! context.device.makeComputePipelineState(function: lib.makeFunction(name: "finalize_blend")!)
        previewStepPipe = try! context.device.makeComputePipelineState(function: lib.makeFunction(name: "preview_step")!)
    }

    public func blend(images: [MTLTexture], focusMaps: [MTLTexture], verbose: Bool = false) throws -> MTLTexture {
        guard images.count == focusMaps.count, !images.isEmpty else {
            throw NSError(domain: "DepthMap", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid input"])
        }
        if verbose { logger.info("Performing Advanced D-Map blending with Edge-Preserving smoothing...") }
        return try blendGPU(images: images, focusMaps: focusMaps)
    }

    /// O(1) incremental preview step — streaming WTA, no full re-blend each frame.
    /// Call once per image in order; each call is O(1) GPU work regardless of how many
    /// images have been processed so far (total cost is O(N) across all N images).
    ///
    /// - Parameters:
    ///   - newImage:   The next source image to consider.
    ///   - newFocusMap: Its focus quality map (R channel carries the score).
    ///   - bestImage:  The current best-so-far preview texture, or nil on the first call.
    ///   - bestScore:  The current best-so-far score texture, or nil on the first call.
    /// - Returns: Updated (bestImage, bestScore) — reuse these as inputs on the next call.
    public func blendPreviewStep(
        newImage: MTLTexture,
        newFocusMap: MTLTexture,
        bestImage: MTLTexture?,
        bestScore: MTLTexture?
    ) throws -> (MTLTexture, MTLTexture) {
        let width  = newImage.width
        let height = newImage.height
        let tg  = MTLSize(width: 16, height: 16, depth: 1)
        let tgc = MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1)

        let outImage: MTLTexture
        let outScore: MTLTexture

        if let prevImage = bestImage, let prevScore = bestScore {
            outImage = prevImage
            outScore = prevScore
        } else {
            // First frame: allocate persistent textures and initialise score to -1
            outImage = try createTexture(width: width, height: height, format: .rgba32Float)
            outScore = try createTexture(width: width, height: height, format: .r32Float)
            // init_maps writes float4(-1) to texture(0) — perfect initial "worst score"
            let dummy = try createTexture(width: width, height: height, format: .r32Float)
            guard let initCmd = context.commandQueue.makeCommandBuffer(),
                  let initEnc = initCmd.makeComputeCommandEncoder() else {
                throw NSError(domain: "DepthMap", code: -1, userInfo: [NSLocalizedDescriptionKey: "init cmd failed"])
            }
            initEnc.setComputePipelineState(initPipe)
            initEnc.setTexture(outScore, index: 0)
            initEnc.setTexture(dummy,    index: 1)
            initEnc.dispatchThreadgroups(tgc, threadsPerThreadgroup: tg)
            initEnc.endEncoding()
            initCmd.commit()
            initCmd.waitUntilCompleted()
        }

        // Smooth the focus score spatially before WTA comparison.
        // Blurring prevents per-pixel noise in the focus map from causing "grain" in the
        // preview — the WTA now selects contiguous regions instead of scattered pixels.
        // This only affects the preview; PyBlend final quality is completely unchanged.
        let smoothedScore = try blurFocusScore(focusMap: newFocusMap, sigma: 8.0,
                                               width: width, height: height, tg: tg, tgc: tgc)

        // Update bestImage/bestScore with this new image (O(1) GPU work)
        guard let cmd = context.commandQueue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else {
            throw NSError(domain: "DepthMap", code: -1, userInfo: [NSLocalizedDescriptionKey: "preview cmd failed"])
        }
        enc.setComputePipelineState(previewStepPipe)
        enc.setTexture(newImage,      index: 0)
        enc.setTexture(smoothedScore, index: 1)  // blurred score → smooth region selection
        enc.setTexture(outImage,      index: 2)
        enc.setTexture(outScore,      index: 3)
        enc.dispatchThreadgroups(tgc, threadsPerThreadgroup: tg)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        return (outImage, outScore)
    }

    /// Gaussian-blur the R-channel focus score from an RGBA or R32Float focus map.
    /// Returns an R32Float texture with the spatially smoothed score.
    private func blurFocusScore(focusMap: MTLTexture, sigma: Float,
                                width: Int, height: Int,
                                tg: MTLSize, tgc: MTLSize) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        guard let tmpH    = context.device.makeTexture(descriptor: desc),
              let blurred = context.device.makeTexture(descriptor: desc) else {
            throw NSError(domain: "DepthMap", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Blur texture alloc failed"])
        }
        var sigmaVal = sigma
        guard let cmd = context.commandQueue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else {
            throw NSError(domain: "DepthMap", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Blur cmd failed"])
        }
        // Horizontal pass: RGBA/R32Float focusMap → R32Float tmpH
        enc.setComputePipelineState(blurHPipe)
        enc.setTexture(focusMap, index: 0)
        enc.setTexture(tmpH,     index: 1)
        enc.setBytes(&sigmaVal, length: 4, index: 0)
        enc.dispatchThreadgroups(tgc, threadsPerThreadgroup: tg)
        // Vertical pass: R32Float tmpH → R32Float blurred
        enc.setComputePipelineState(blurVPipe)
        enc.setTexture(tmpH,     index: 0)
        enc.setTexture(blurred,  index: 1)
        enc.setBytes(&sigmaVal, length: 4, index: 0)
        enc.dispatchThreadgroups(tgc, threadsPerThreadgroup: tg)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        return blurred
    }

    private func createTexture(width: Int, height: Int, format: MTLPixelFormat) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        guard let tex = context.device.makeTexture(descriptor: desc) else {
            throw NSError(domain: "DepthMap", code: -1, userInfo: [NSLocalizedDescriptionKey: "Texture alloc failed"])
        }
        return tex
    }

    private func blendGPU(images: [MTLTexture], focusMaps: [MTLTexture]) throws -> MTLTexture {
        let width = images[0].width
        let height = images[0].height

        let tgSize  = MTLSize(width: 16, height: 16, depth: 1)
        let tgCount = MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1)

        // ── Shared textures ──────────────────────────────────────────────────
        let maxScoreTex  = try createTexture(width: width, height: height, format: .r32Float)
        let maxIndexTex  = try createTexture(width: width, height: height, format: .r32Float)
        let maxScoreTmp  = try createTexture(width: width, height: height, format: .r32Float)
        let maxIndexTmp  = try createTexture(width: width, height: height, format: .r32Float)
        let blurTmpTex   = try createTexture(width: width, height: height, format: .r32Float)
        let focusBlurred = try createTexture(width: width, height: height, format: .r32Float)

        var curScore = maxScoreTex
        var curIndex = maxIndexTex
        var nxtScore = maxScoreTmp
        var nxtIndex = maxIndexTmp

        // ── Phase 1: Winner-Takes-All using blurred focus maps ───────────────
        // All work uses compute encoders only — no MPS.
        guard let cmdBuf1 = context.commandQueue.makeCommandBuffer() else { throw NSError() }

        // 1a. Initialize score / index maps
        guard let encInit = cmdBuf1.makeComputeCommandEncoder() else { throw NSError() }
        encInit.setComputePipelineState(initPipe)
        encInit.setTexture(maxScoreTex, index: 0)
        encInit.setTexture(maxIndexTex, index: 1)
        encInit.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)
        encInit.endEncoding()

        // 1b. For each focus map: blur (H then V) → update WTA
        var focusSigma: Float = 3.0
        for i in 0..<focusMaps.count {
            // H blur
            guard let encH = cmdBuf1.makeComputeCommandEncoder() else { throw NSError() }
            encH.setComputePipelineState(blurHPipe)
            encH.setTexture(focusMaps[i], index: 0)
            encH.setTexture(blurTmpTex,   index: 1)
            encH.setBytes(&focusSigma, length: 4, index: 0)
            encH.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)
            encH.endEncoding()

            // V blur
            guard let encV = cmdBuf1.makeComputeCommandEncoder() else { throw NSError() }
            encV.setComputePipelineState(blurVPipe)
            encV.setTexture(blurTmpTex,   index: 0)
            encV.setTexture(focusBlurred, index: 1)
            encV.setBytes(&focusSigma, length: 4, index: 0)
            encV.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)
            encV.endEncoding()

            // WTA update
            guard let encUpd = cmdBuf1.makeComputeCommandEncoder() else { throw NSError() }
            encUpd.setComputePipelineState(updatePipe)
            encUpd.setTexture(focusBlurred, index: 0)
            encUpd.setTexture(curScore,     index: 1)
            encUpd.setTexture(nxtScore,     index: 2)
            encUpd.setTexture(curIndex,     index: 3)
            encUpd.setTexture(nxtIndex,     index: 4)
            var idx = UInt32(i)
            encUpd.setBytes(&idx, length: MemoryLayout<UInt32>.stride, index: 0)
            encUpd.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)
            encUpd.endEncoding()

            swap(&curScore, &nxtScore)
            swap(&curIndex, &nxtIndex)
        }

        cmdBuf1.commit()
        cmdBuf1.waitUntilCompleted()

        // ── Phase 2: Soft-mask blending ──────────────────────────────────────
        let maskTex       = try createTexture(width: width, height: height, format: .r32Float)
        let maskBlurTmp   = try createTexture(width: width, height: height, format: .r32Float)
        let maskBlurred   = try createTexture(width: width, height: height, format: .r32Float)
        let resultAcc1    = try createTexture(width: width, height: height, format: .rgba32Float)
        let resultAcc2    = try createTexture(width: width, height: height, format: .rgba32Float)
        let weightSum1    = try createTexture(width: width, height: height, format: .r32Float)
        let weightSum2    = try createTexture(width: width, height: height, format: .r32Float)
        let finalOut      = try createTexture(width: width, height: height, format: .rgba32Float)

        var curRes = resultAcc1
        var nexRes = resultAcc2
        var curWt  = weightSum1
        var nexWt  = weightSum2

        guard let cmdBuf2 = context.commandQueue.makeCommandBuffer() else { throw NSError() }

        // 2a. Zero-init accumulators
        guard let encZ1 = cmdBuf2.makeComputeCommandEncoder() else { throw NSError() }
        encZ1.setComputePipelineState(zeroTexPipe)
        encZ1.setTexture(resultAcc1, index: 0)
        encZ1.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)
        encZ1.endEncoding()

        guard let encZ2 = cmdBuf2.makeComputeCommandEncoder() else { throw NSError() }
        encZ2.setComputePipelineState(zeroTexPipe)
        encZ2.setTexture(weightSum1, index: 0)
        encZ2.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)
        encZ2.endEncoding()

        // 2b. For each image: create mask → blur mask (H+V) → accumulate
        var maskSigma: Float = 5.0
        for i in 0..<images.count {
            // Hard mask
            guard let encM = cmdBuf2.makeComputeCommandEncoder() else { throw NSError() }
            encM.setComputePipelineState(maskPipe)
            encM.setTexture(curIndex, index: 0)
            encM.setTexture(maskTex,  index: 1)
            var tgt = UInt32(i)
            encM.setBytes(&tgt, length: MemoryLayout<UInt32>.stride, index: 0)
            encM.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)
            encM.endEncoding()

            // H blur mask
            guard let encMH = cmdBuf2.makeComputeCommandEncoder() else { throw NSError() }
            encMH.setComputePipelineState(blurHPipe)
            encMH.setTexture(maskTex,    index: 0)
            encMH.setTexture(maskBlurTmp, index: 1)
            encMH.setBytes(&maskSigma, length: 4, index: 0)
            encMH.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)
            encMH.endEncoding()

            // V blur mask
            guard let encMV = cmdBuf2.makeComputeCommandEncoder() else { throw NSError() }
            encMV.setComputePipelineState(blurVPipe)
            encMV.setTexture(maskBlurTmp, index: 0)
            encMV.setTexture(maskBlurred, index: 1)
            encMV.setBytes(&maskSigma, length: 4, index: 0)
            encMV.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)
            encMV.endEncoding()

            // Accumulate
            guard let encA = cmdBuf2.makeComputeCommandEncoder() else { throw NSError() }
            encA.setComputePipelineState(accumPipe)
            encA.setTexture(images[i], index: 0)
            encA.setTexture(maskBlurred, index: 1)
            encA.setTexture(curRes,    index: 2)
            encA.setTexture(nexRes,    index: 3)
            encA.setTexture(curWt,     index: 4)
            encA.setTexture(nexWt,     index: 5)
            encA.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)
            encA.endEncoding()

            swap(&curRes, &nexRes)
            swap(&curWt,  &nexWt)
        }

        // 2c. Finalize
        guard let encFin = cmdBuf2.makeComputeCommandEncoder() else { throw NSError() }
        encFin.setComputePipelineState(finalizePipe)
        encFin.setTexture(curRes,   index: 0)
        encFin.setTexture(curWt,    index: 1)
        encFin.setTexture(finalOut, index: 2)
        encFin.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)
        encFin.endEncoding()

        cmdBuf2.commit()
        cmdBuf2.waitUntilCompleted()

        return finalOut
    }
}