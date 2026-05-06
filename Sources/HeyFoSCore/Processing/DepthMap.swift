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

    // Initialize max-score map to -1 (any real focus score will exceed this)
    kernel void init_max_score(
        texture2d<float, access::write> maxScore [[texture(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= maxScore.get_width() || gid.y >= maxScore.get_height()) return;
        maxScore.write(float4(-1.0), gid);
    }

    // Ping-pong max-score update: tracks only the best score, not image index.
    // (Index not needed — softmax replaces the argmax + binary-mask approach.)
    kernel void update_max_score_only(
        texture2d<float, access::read>  focus    [[texture(0)]],
        texture2d<float, access::read>  scoreIn  [[texture(1)]],
        texture2d<float, access::write> scoreOut [[texture(2)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= focus.get_width() || gid.y >= focus.get_height()) return;
        float s = focus.read(gid).r;
        float b = scoreIn.read(gid).r;
        scoreOut.write(float4(s > b ? s : b), gid);
    }

    // Per-pixel softmax weight: w_i = exp((score_i - maxScore) / (maxScore * tempFactor))
    // Replaces hard binary WTA mask. Produces smooth, physically-correct transitions:
    //   tempFactor → 0  :  approaches hard WTA (one winner per pixel)
    //   tempFactor = 0.3:  pixel at 70% of max score gets exp(-1) ≈ 37% weight
    //   tempFactor large :  more mixing across images
    // Weights are un-normalised; accum_blend + finalize_blend handle the normalisation.
    kernel void softmax_weight(
        texture2d<float, access::read>  focus      [[texture(0)]],
        texture2d<float, access::read>  maxScore   [[texture(1)]],
        texture2d<float, access::write> output     [[texture(2)]],
        constant float                  &tempFactor [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
        float s = focus.read(gid).r;
        float m = maxScore.read(gid).r;
        float w;
        if (m > 1e-7f) {
            float T = m * max(tempFactor, 1e-4f);
            w = exp((s - m) / T);
        } else {
            w = 1.0f;   // all scores near zero: blend equally
        }
        output.write(float4(w, 0.0f, 0.0f, 1.0f), gid);
    }
    """

    // ── Pipeline states cached at init — never recompiled ────────────────────
    private let initPipe:            MTLComputePipelineState
    private let zeroTexPipe:         MTLComputePipelineState
    private let blurHPipe:           MTLComputePipelineState
    private let blurVPipe:           MTLComputePipelineState
    private let updatePipe:          MTLComputePipelineState   // kept for blendPreviewStep internals
    private let maskPipe:            MTLComputePipelineState   // kept for compatibility
    private let accumPipe:           MTLComputePipelineState
    private let finalizePipe:        MTLComputePipelineState
    private let previewStepPipe:     MTLComputePipelineState
    private let initScorePipe:       MTLComputePipelineState   // init maxScore to -1
    private let updateScoreOnlyPipe: MTLComputePipelineState   // ping-pong maxScore (no index)
    private let softmaxWeightPipe:   MTLComputePipelineState   // softmax weight per pixel

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
        previewStepPipe     = try! context.device.makeComputePipelineState(function: lib.makeFunction(name: "preview_step")!)
        initScorePipe       = try! context.device.makeComputePipelineState(function: lib.makeFunction(name: "init_max_score")!)
        updateScoreOnlyPipe = try! context.device.makeComputePipelineState(function: lib.makeFunction(name: "update_max_score_only")!)
        softmaxWeightPipe   = try! context.device.makeComputePipelineState(function: lib.makeFunction(name: "softmax_weight")!)
    }

    /// Full WTA + soft-mask blend with optional per-image progress and preview.
    /// Uses one command buffer per image to avoid Metal encoder-count limits.
    public func blend(
        images: [MTLTexture],
        focusMaps: [MTLTexture],
        verbose: Bool = false,
        progressHandler: ((Double, String) -> Void)? = nil,
        partialPreviewCallback: ((Int, Int, MTLTexture) throws -> Void)? = nil
    ) throws -> MTLTexture {
        guard images.count == focusMaps.count, !images.isEmpty else {
            throw NSError(domain: "DepthMap", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid input"])
        }
        if verbose { logger.info("Performing DMap blending (streaming, one cmd-buffer per image)...") }
        return try blendGPU(images: images, focusMaps: focusMaps,
                            progressHandler: progressHandler,
                            partialPreviewCallback: partialPreviewCallback)
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

    // MARK: - Public Streaming API for DMap

    /// Mutable state shared between DMap Phase 1 and Phase 2 streaming passes.
    public struct DMapStreamingState {
        public var curScore:     MTLTexture   // per-pixel max blurred focus score
        public var nxtScore:     MTLTexture   // ping-pong buffer
        public var blurTmpTex:   MTLTexture   // scratch for blur horizontal pass
        public var focusBlurred: MTLTexture   // scratch for blurred focus map
        public var softmaxWtTex: MTLTexture   // scratch for per-pixel softmax weight
        public let width:        Int
        public let height:       Int
    }

    /// Allocate work textures and initialise maxScore to –1 (less than any real score).
    /// Call once before Phase 1 streaming.
    public func makeDMapStreamingState(width: Int, height: Int) throws -> DMapStreamingState {
        let cur     = try createTexture(width: width, height: height, format: .r32Float)
        let nxt     = try createTexture(width: width, height: height, format: .r32Float)
        let tmp     = try createTexture(width: width, height: height, format: .r32Float)
        let blurred = try createTexture(width: width, height: height, format: .r32Float)
        let softmax = try createTexture(width: width, height: height, format: .r32Float)
        let tg  = MTLSize(width: 16, height: 16, depth: 1)
        let tgc = MTLSize(width: (width+15)/16, height: (height+15)/16, depth: 1)
        guard let initCmd = context.commandQueue.makeCommandBuffer(),
              let initEnc = initCmd.makeComputeCommandEncoder() else {
            throw NSError(domain: "DepthMap", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "makeDMapStreamingState: init cmd failed"])
        }
        initEnc.setComputePipelineState(initScorePipe)
        initEnc.setTexture(cur, index: 0)
        initEnc.dispatchThreadgroups(tgc, threadsPerThreadgroup: tg)
        initEnc.endEncoding()
        initCmd.commit()
        initCmd.waitUntilCompleted()
        return DMapStreamingState(curScore: cur, nxtScore: nxt,
                                  blurTmpTex: tmp, focusBlurred: blurred,
                                  softmaxWtTex: softmax, width: width, height: height)
    }

    /// Phase 1 (streaming): blur one image's focus map and update the per-pixel max score.
    /// Call once per image in order.  `state.curScore` accumulates the running maximum.
    public func dmapPhase1Accumulate(focusMap: MTLTexture, state: inout DMapStreamingState) throws {
        var sigma: Float = 5.0
        let tg  = MTLSize(width: 16, height: 16, depth: 1)
        let tgc = MTLSize(width: (state.width+15)/16, height: (state.height+15)/16, depth: 1)
        guard let cmd = context.commandQueue.makeCommandBuffer() else {
            throw NSError(domain: "DepthMap", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Phase1: cmd alloc failed"])
        }
        guard let encH = cmd.makeComputeCommandEncoder() else { throw NSError() }
        encH.setComputePipelineState(blurHPipe)
        encH.setTexture(focusMap,          index: 0)
        encH.setTexture(state.blurTmpTex,  index: 1)
        encH.setBytes(&sigma, length: 4,   index: 0)
        encH.dispatchThreadgroups(tgc, threadsPerThreadgroup: tg)
        encH.endEncoding()

        guard let encV = cmd.makeComputeCommandEncoder() else { throw NSError() }
        encV.setComputePipelineState(blurVPipe)
        encV.setTexture(state.blurTmpTex,   index: 0)
        encV.setTexture(state.focusBlurred, index: 1)
        encV.setBytes(&sigma, length: 4,    index: 0)
        encV.dispatchThreadgroups(tgc, threadsPerThreadgroup: tg)
        encV.endEncoding()

        guard let encUpd = cmd.makeComputeCommandEncoder() else { throw NSError() }
        encUpd.setComputePipelineState(updateScoreOnlyPipe)
        encUpd.setTexture(state.focusBlurred, index: 0)
        encUpd.setTexture(state.curScore,     index: 1)
        encUpd.setTexture(state.nxtScore,     index: 2)
        encUpd.dispatchThreadgroups(tgc, threadsPerThreadgroup: tg)
        encUpd.endEncoding()

        cmd.commit()
        cmd.waitUntilCompleted()
        swap(&state.curScore, &state.nxtScore)  // curScore is now updated
    }

    /// Phase 2 (streaming): compute softmax weight from the (now final) maxScore and
    /// pyramid-accumulate one image.  Must be called after all Phase 1 calls finish.
    /// `pyramidBlender` must be initialised with `makeSoftBlendAccumulators(forImage:)`.
    public func dmapPhase2Accumulate(
        image:          MTLTexture,
        focusMap:       MTLTexture,
        state:          DMapStreamingState,
        accValues:      [MTLTexture],
        accWeights:     [MTLTexture],
        pyramidBlender: PyBlend
    ) throws {
        var sigma:      Float = 5.0
        var tempFactor: Float = 0.3
        let tg  = MTLSize(width: 16, height: 16, depth: 1)
        let tgc = MTLSize(width: (state.width+15)/16, height: (state.height+15)/16, depth: 1)
        guard let cmd = context.commandQueue.makeCommandBuffer() else {
            throw NSError(domain: "DepthMap", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Phase2: cmd alloc failed"])
        }
        // Blur focus map (σ=5, same as Phase 1)
        guard let encH = cmd.makeComputeCommandEncoder() else { throw NSError() }
        encH.setComputePipelineState(blurHPipe)
        encH.setTexture(focusMap,          index: 0)
        encH.setTexture(state.blurTmpTex,  index: 1)
        encH.setBytes(&sigma, length: 4,   index: 0)
        encH.dispatchThreadgroups(tgc, threadsPerThreadgroup: tg)
        encH.endEncoding()

        guard let encV = cmd.makeComputeCommandEncoder() else { throw NSError() }
        encV.setComputePipelineState(blurVPipe)
        encV.setTexture(state.blurTmpTex,   index: 0)
        encV.setTexture(state.focusBlurred, index: 1)
        encV.setBytes(&sigma, length: 4,    index: 0)
        encV.dispatchThreadgroups(tgc, threadsPerThreadgroup: tg)
        encV.endEncoding()

        // Softmax weight: w = exp((score - maxScore) / (maxScore × tempFactor))
        guard let encSW = cmd.makeComputeCommandEncoder() else { throw NSError() }
        encSW.setComputePipelineState(softmaxWeightPipe)
        encSW.setTexture(state.focusBlurred, index: 0)
        encSW.setTexture(state.curScore,     index: 1)   // final maxScore from Phase 1
        encSW.setTexture(state.softmaxWtTex, index: 2)
        encSW.setBytes(&tempFactor, length: 4, index: 0)
        encSW.dispatchThreadgroups(tgc, threadsPerThreadgroup: tg)
        encSW.endEncoding()

        cmd.commit()
        cmd.waitUntilCompleted()

        // Laplacian pyramid × softmax weight → pyramid accumulators
        try pyramidBlender.softBlendAccumulateImage(
            image, weightMap: state.softmaxWtTex,
            accValues: accValues, accWeights: accWeights)
    }

    private func blendGPU(
        images: [MTLTexture],
        focusMaps: [MTLTexture],
        progressHandler: ((Double, String) -> Void)? = nil,
        partialPreviewCallback: ((Int, Int, MTLTexture) throws -> Void)? = nil
    ) throws -> MTLTexture {
        let n       = images.count
        let width   = images[0].width
        let height  = images[0].height
        let tgSize  = MTLSize(width: 16, height: 16, depth: 1)
        let tgCount = MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1)

        // ── Allocate work textures ────────────────────────────────────────────
        let maxScoreTex1  = try createTexture(width: width, height: height, format: .r32Float)
        let maxScoreTex2  = try createTexture(width: width, height: height, format: .r32Float)
        let blurTmpTex    = try createTexture(width: width, height: height, format: .r32Float)
        let focusBlurred  = try createTexture(width: width, height: height, format: .r32Float)
        let softmaxWtTex  = try createTexture(width: width, height: height, format: .r32Float)

        var curScore = maxScoreTex1
        var nxtScore = maxScoreTex2

        // ── Init maxScore = -1 ────────────────────────────────────────────────
        guard let initCmd = context.commandQueue.makeCommandBuffer(),
              let initEnc = initCmd.makeComputeCommandEncoder() else { throw NSError() }
        initEnc.setComputePipelineState(initScorePipe)
        initEnc.setTexture(curScore, index: 0)
        initEnc.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)
        initEnc.endEncoding()
        initCmd.commit()
        initCmd.waitUntilCompleted()

        // ── Phase 1: find per-pixel max focus score ──────────────────────────
        // Gaussian blur (σ=5) smooths energy within regions while one cmd-buffer per
        // image avoids the Metal encoder-count hang seen with large stacks.
        // The WTA streaming preview runs in parallel using blendPreviewStep.
        var previewTex: MTLTexture? = nil
        var previewScore: MTLTexture? = nil
        var focusSigma: Float = 5.0   // larger than before → cleaner region boundaries

        for i in 0..<n {
            guard let cmd = context.commandQueue.makeCommandBuffer() else { throw NSError() }

            guard let encH = cmd.makeComputeCommandEncoder() else { throw NSError() }
            encH.setComputePipelineState(blurHPipe)
            encH.setTexture(focusMaps[i], index: 0)
            encH.setTexture(blurTmpTex,   index: 1)
            encH.setBytes(&focusSigma, length: 4, index: 0)
            encH.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)
            encH.endEncoding()

            guard let encV = cmd.makeComputeCommandEncoder() else { throw NSError() }
            encV.setComputePipelineState(blurVPipe)
            encV.setTexture(blurTmpTex,   index: 0)
            encV.setTexture(focusBlurred, index: 1)
            encV.setBytes(&focusSigma, length: 4, index: 0)
            encV.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)
            encV.endEncoding()

            guard let encUpd = cmd.makeComputeCommandEncoder() else { throw NSError() }
            encUpd.setComputePipelineState(updateScoreOnlyPipe)
            encUpd.setTexture(focusBlurred, index: 0)
            encUpd.setTexture(curScore,     index: 1)
            encUpd.setTexture(nxtScore,     index: 2)
            encUpd.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)
            encUpd.endEncoding()

            cmd.commit()
            cmd.waitUntilCompleted()
            swap(&curScore, &nxtScore)
            // curScore is now updated maxScore map through image i

            // Streaming WTA preview (separate internal tracking, unaffected by maxScore)
            if let callback = partialPreviewCallback {
                (previewTex, previewScore) = try blendPreviewStep(
                    newImage:    images[i],
                    newFocusMap: focusMaps[i],
                    bestImage:   previewTex,
                    bestScore:   previewScore
                )
                try callback(i, n, previewTex!)
            }
            progressHandler?(Double(i + 1) / Double(n) * 0.45,
                             "Analysing depth \(i + 1)/\(n)…")
        }
        // curScore = per-pixel max blurred focus score across all N images.

        // ── Phase 2: Laplacian pyramid blend with softmax weights ─────────────────────
        // Matches ShineStacker's weighted_pyramid_blend: per-image softmax weights drive
        // a Gaussian weight pyramid × Laplacian image pyramid at each spatial scale.
        // Far better detail preservation than the previous flat weighted-average.
        var tempFactor: Float = 0.3
        let pyramidBlender = PyBlend(context: context, levels: 5, blurRadius: 2.0)
        let (accValues, accWeights) = try pyramidBlender.makeSoftBlendAccumulators(forImage: images[0])

        for i in 0..<n {
            guard let cmd = context.commandQueue.makeCommandBuffer() else { throw NSError() }

            // Re-blur focus map (same σ as Phase 1; avoids caching O(N) full-res textures)
            guard let encH = cmd.makeComputeCommandEncoder() else { throw NSError() }
            encH.setComputePipelineState(blurHPipe)
            encH.setTexture(focusMaps[i], index: 0)
            encH.setTexture(blurTmpTex,   index: 1)
            encH.setBytes(&focusSigma, length: 4, index: 0)
            encH.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)
            encH.endEncoding()

            guard let encV = cmd.makeComputeCommandEncoder() else { throw NSError() }
            encV.setComputePipelineState(blurVPipe)
            encV.setTexture(blurTmpTex,   index: 0)
            encV.setTexture(focusBlurred, index: 1)
            encV.setBytes(&focusSigma, length: 4, index: 0)
            encV.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)
            encV.endEncoding()

            // Softmax weight: w = exp((blurredScore - maxScore) / (maxScore * tempFactor))
            guard let encSW = cmd.makeComputeCommandEncoder() else { throw NSError() }
            encSW.setComputePipelineState(softmaxWeightPipe)
            encSW.setTexture(focusBlurred, index: 0)
            encSW.setTexture(curScore,     index: 1)  // curScore = maxScore after Phase 1
            encSW.setTexture(softmaxWtTex, index: 2)
            encSW.setBytes(&tempFactor, length: 4, index: 0)
            encSW.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)
            encSW.endEncoding()

            cmd.commit()
            cmd.waitUntilCompleted()

            // Pyramid accumulate: Laplacian(image[i]) × GaussianPyramid(softmaxWeight)
            try pyramidBlender.softBlendAccumulateImage(images[i], weightMap: softmaxWtTex,
                                                        accValues: accValues, accWeights: accWeights)

            progressHandler?(0.45 + Double(i + 1) / Double(n) * 0.50,
                             "Blending \(i + 1)/\(n)…")
        }

        // Finalize: normalize each pyramid level → collapse → result
        let result = try pyramidBlender.softBlendFinalize(accValues: accValues, accWeights: accWeights)
        try partialPreviewCallback?(n - 1, n, result)
        return result
    }
}