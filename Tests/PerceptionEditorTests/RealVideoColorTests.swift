@preconcurrency import AVFoundation
import Foundation
import Metal
import Testing
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
