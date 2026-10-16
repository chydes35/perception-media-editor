@preconcurrency import AVFoundation
import Foundation
import CoreImage
import Metal
import Testing
import simd
@testable import PerceptionEditor

/// Source color detection on real Lumix S5 files. Run with
/// PME_VLOG_SHORT=/Volumes/ExSSD1/Pictures/110_PANA/P1107158.MOV (V-Log, tagged BT.709) and
/// PME_REC709_8BIT=/Volumes/ExSSD1/Pictures/110_PANA/P1107172.MOV (standard gamma, 8-bit).
@MainActor
struct RealVideoColorTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PME_VLOG_SHORT"] != nil))
    func lumixVLogIsDetectedDespiteItsBT709Tags() async throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PME_VLOG_SHORT"]!)
        let color = try #require(await VideoMediaService.shared.metadata(for: url).sourceColor)
        print("V-Log sample: \(color.summary)")
        #expect(color.transfer == .vLog && color.gamut == .vGamut && color.detectedFrom == .panasonicMetadata)
        #expect(color.range == .full && color.matrix == .rec709 && color.bitDepth == 10 && color.chroma == .yuv422)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PME_REC709_8BIT"] != nil))
    func lumixStandardGammaStaysRec709() async throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PME_REC709_8BIT"]!)
        let color = try #require(await VideoMediaService.shared.metadata(for: url).sourceColor)
        print("Standard sample: \(color.summary)")
        #expect(color.transfer == .rec709 && color.gamut == .rec709 && !color.isLog)
        #expect(color.range == .video && color.bitDepth == 8 && color.chroma == .yuv420 && color.detectedFrom == .panasonicMetadata)
    }

    /// Task 3 on real footage: a UHD V-Log frame is read as full-range `xf22` (bit-exact with ffmpeg per
    /// the Task 0 record), decoded on the GPU, and compared with the BT.709 equations in Double on the
    /// even columns, where 4:2:2 chroma needs no interpolation.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PME_VLOG_SHORT"] != nil && MTLCreateSystemDefaultDevice() != nil))
    func gpuDecodeOfARealFullRangeFrameMatchesTheEquations() async throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PME_VLOG_SHORT"]!)
        let color = try #require(await VideoMediaService.shared.metadata(for: url).sourceColor)
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_422YpCbCr10BiPlanarFullRange
        ])
        reader.add(output)
        #expect(reader.startReading())
        let sample = try #require(output.copyNextSampleBuffer())
        reader.cancelReading()
        let buffer = try #require(CMSampleBufferGetImageBuffer(sample))
        #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_422YpCbCr10BiPlanarFullRange, "Full range must arrive as xf22")

        let kernels = try VideoColorKernels()
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let texture = try kernels.makeWorkingTexture(width: width, height: height)
        let gpuMilliseconds = try Self.timedDecodes(of: buffer, matrix: color.matrix, into: texture, using: kernels, runs: 10)
        print("GPU decode of a \(width)x\(height) xf22 frame: median \(String(format: "%.2f", gpuMilliseconds.sorted()[5])) ms")

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let lumaBase = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)), lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) / 2
        let chromaBase = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 1)), chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) / 2
        let luma = lumaBase.assumingMemoryBound(to: UInt16.self), chroma = chromaBase.assumingMemoryBound(to: UInt16.self)
        let coefficients = color.matrix.coefficients
        var worst = 0.0, checked = 0
        for y in stride(from: 3, to: height, by: 61) {
            for x in stride(from: 2, to: width, by: 120) { // Even columns only.
                let yy = Double(luma[y * lumaStride + x] >> 6) / 1023
                let cb = (Double(chroma[y * chromaStride + x] >> 6) - 512) / 1023
                let cr = (Double(chroma[y * chromaStride + x + 1] >> 6) - 512) / 1023
                let r = yy + 2 * (1 - coefficients.kr) * cr, b = yy + 2 * (1 - coefficients.kb) * cb
                let g = (yy - coefficients.kr * r - coefficients.kb * b) / (1 - coefficients.kr - coefficients.kb)
                var half = [Float16](repeating: 0, count: 4)
                texture.getBytes(&half, bytesPerRow: 8, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
                worst = max(worst, abs(Double(half[0]) - r), abs(Double(half[1]) - g), abs(Double(half[2]) - b))
                checked += 1
            }
        }
        print("Real-frame decode: \(checked) pixels, worst error \(String(format: "%.3f", worst * 1023)) of 1023 levels")
        #expect(checked > 1000)
        #expect(worst <= 0.3 / 1023, "Worst error \(worst * 1023) of 1023 levels")
    }

    /// Gate G5 (precision part) on real 10-bit content: the top band of `PME_VLOG_SKY` (trees and an
    /// overcast sky in P1107210), decoded on the GPU, graded with the sky HSL setting through
    /// `MediaColorRenderer`, against `ColorGrading.applyHSL` in Double on the same decoded values.
    /// The visual part of G5 (no bands in a clear blue sky) needs footage with such a sky.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PME_VLOG_SKY"] != nil && MTLCreateSystemDefaultDevice() != nil))
    func hslOnRealTenBitSkyFollowsTheExactCurve() async throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PME_VLOG_SKY"]!)
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_422YpCbCr10BiPlanarFullRange
        ])
        reader.add(output)
        #expect(reader.startReading())
        let sample = try #require(output.copyNextSampleBuffer())
        reader.cancelReading()
        let buffer = try #require(CMSampleBufferGetImageBuffer(sample))
        let kernels = try VideoColorKernels()
        let width = CVPixelBufferGetWidth(buffer), bandHeight = 240
        let texture = try kernels.makeWorkingTexture(width: width, height: CVPixelBufferGetHeight(buffer))
        _ = try Self.timedDecodes(of: buffer, matrix: .rec709, into: texture, using: kernels, runs: 1)
        var halves = [Float16](repeating: 0, count: width * bandHeight * 4)
        texture.getBytes(&halves, bytesPerRow: width * 8, from: MTLRegionMake2D(0, 0, width, bandHeight), mipmapLevel: 0)
        let decoded = (0 ..< width * bandHeight).map { SIMD3(Float(halves[$0 * 4]), Float(halves[$0 * 4 + 1]), Float(halves[$0 * 4 + 2])) }

        var hsl = HSLAdjustments()
        hsl.blue = HSLBandAdjustment(hue: 0, saturation: 0.6, luminance: -0.4)
        hsl.aqua = HSLBandAdjustment(hue: 0.2, saturation: 0.3, luminance: -0.2)
        hsl.green = HSLBandAdjustment(hue: -0.2, saturation: 0.4, luminance: 0.1)
        var adjustments = PhotoAdjustments()
        adjustments.hsl = hsl
        // As production does it: Core Image reads the decoded texture and writes another one.
        let space = try #require(CGColorSpace(name: CGColorSpace.extendedSRGB))
        let graded = try kernels.makeWorkingTexture(width: width, height: CVPixelBufferGetHeight(buffer))
        try Self.grade(texture, adjustments: adjustments, space: space, into: graded, runtime: kernels.runtime)
        var result = [Float16](repeating: 0, count: width * bandHeight * 4)
        graded.getBytes(&result, bytesPerRow: width * 8, from: MTLRegionMake2D(0, 0, width, bandHeight), mipmapLevel: 0)

        var worst: Float = 0, changed = 0
        var outputLevels = Set<Int>(), referenceLevels = Set<Int>()
        for index in decoded.indices {
            let c = decoded[index]
            let r = ColorGrading.applyHSL(hsl, r: Double(c.x), g: Double(c.y), b: Double(c.z))
            let reference = SIMD3(Float(r.r), Float(r.g), Float(r.b))
            let shown = SIMD3(Float(result[index * 4]), Float(result[index * 4 + 1]), Float(result[index * 4 + 2]))
            worst = max(worst, simd_abs(shown - reference).max())
            if simd_abs(reference - c).max() > 1.0 / 1023 { changed += 1 }
            outputLevels.insert(Int((shown.z * 1023).rounded()))
            referenceLevels.insert(Int((reference.z * 1023).rounded()))
        }
        print("Real sky band: \(decoded.count) pixels, \(changed) moved by the grade by more than one level, worst error \(worst * 1023) of 1023, blue levels \(outputLevels.count) of \(referenceLevels.count)")
        #expect(worst <= 1.0 / 1023, "Worst error \(worst * 1023) of 1023 levels (half-float output alone costs up to 0.25)")
        #expect(Double(outputLevels.count) >= 0.95 * Double(referenceLevels.count), "Distinct blue levels \(outputLevels.count) of \(referenceLevels.count)")
    }

    /// Grades a frame texture through `MediaColorRenderer` with Core Image, synchronously on the GPU.
    private static func grade(_ input: MTLTexture, adjustments: PhotoAdjustments, space: CGColorSpace, into output: MTLTexture, runtime: MetalPipelineCache) throws {
        let context = CIContext(mtlCommandQueue: runtime.queue, options: [.workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])
        let image = try #require(CIImage(mtlTexture: input, options: [.colorSpace: space]))
        let commandBuffer = try #require(runtime.queue.makeCommandBuffer())
        context.render(MediaColorRenderer.render(image, adjustments: adjustments, includesGeometry: false), to: output,
                       commandBuffer: commandBuffer, bounds: image.extent, colorSpace: space)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    /// Blocking GPU waits are not allowed in async code, so the timing loop is synchronous.
    private static func timedDecodes(
        of buffer: CVPixelBuffer, matrix: YCbCrMatrix, into texture: MTLTexture, using kernels: VideoColorKernels, runs: Int
    ) throws -> [Double] {
        try (0 ..< runs).map { _ in
            let commandBuffer = try #require(kernels.runtime.queue.makeCommandBuffer())
            try kernels.decode(buffer, matrix: matrix, into: texture, commandBuffer: commandBuffer)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            #expect(commandBuffer.status == .completed)
            return (commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1000
        }
    }
}
