import Foundation
import Metal
import Logging

public class DepthMap {
    private let context: MetalContext
    private let logger = Logger(label: "com.heyfos.depthmap")
    
    public init(context: MetalContext) {
        self.context = context
    }
    
    public func blend(images: [MTLTexture], focusMaps: [MTLTexture], verbose: Bool = false) throws -> MTLTexture {
        guard images.count == focusMaps.count, !images.isEmpty else {
            throw NSError(domain: "DepthMap", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid input"])
        }
        if verbose { logger.info("Performing Advanced D-Map blending with Edge-Preserving smoothing...") }
        return try blendGPU(images: images, focusMaps: focusMaps)
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
        
        let shaderSrc = """
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
        """

        let lib           = try context.device.makeLibrary(source: shaderSrc, options: nil)
        let initPipe      = try context.device.makeComputePipelineState(function: lib.makeFunction(name: "init_maps")!)
        let zeroTexPipe   = try context.device.makeComputePipelineState(function: lib.makeFunction(name: "zero_tex")!)
        let blurHPipe     = try context.device.makeComputePipelineState(function: lib.makeFunction(name: "blur_h")!)
        let blurVPipe     = try context.device.makeComputePipelineState(function: lib.makeFunction(name: "blur_v")!)
        let updatePipe    = try context.device.makeComputePipelineState(function: lib.makeFunction(name: "update_max")!)
        let maskPipe      = try context.device.makeComputePipelineState(function: lib.makeFunction(name: "create_mask")!)
        let accumPipe     = try context.device.makeComputePipelineState(function: lib.makeFunction(name: "accum_blend")!)
        let finalizePipe  = try context.device.makeComputePipelineState(function: lib.makeFunction(name: "finalize_blend")!)

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