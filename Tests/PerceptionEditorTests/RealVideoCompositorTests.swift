@preconcurrency import AVFoundation
import Foundation
import Metal
import Testing
@testable import PerceptionEditor

/// Throughput and memory of the compositor on real UHD V-Log. Run with
/// PME_VIDEO_SAMPLE=/Volumes/ExSSD1/Pictures/110_PANA/P1107157.MOV on the target M1, in release
/// (`-c release`) and with `--no-parallel`. Numbers are printed; the gates are in the plan (G1, G7).
@MainActor
struct RealVideoCompositorTests {
    private struct Unchecked<Value>: @unchecked Sendable { let value: Value }

    private nonisolated static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return status == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    /// Frames per second reading `frames` composed frames, and the peak footprint seen.
    private func measure(_ item: AVPlayerItem, pixelFormat: OSType, frames: Int) async throws -> (fps: Double, peakMB: Double, baselineMB: Double, count: Int) {
        let tracks = Unchecked(value: try await item.asset.loadTracks(withMediaType: .video))
        let job = Unchecked(value: (asset: item.asset, composition: item.videoComposition))
        let result: Unchecked<(Double, Double, Double, Int)> = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let reader = try AVAssetReader(asset: job.value.asset)
                    let output = AVAssetReaderVideoCompositionOutput(
                        videoTracks: tracks.value, videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
                    )
                    output.videoComposition = job.value.composition
                    output.alwaysCopiesSampleData = false
                    reader.add(output)
                    guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
                    let start = Date()
                    let baseline = Self.footprintMB()
                    var count = 0, peak = baseline
                    while let sample = output.copyNextSampleBuffer() {
                        _ = sample
                        count += 1
                        if count % 24 == 0 { peak = max(peak, Self.footprintMB()) }
                    }
                    let seconds = Date().timeIntervalSince(start)
                    continuation.resume(returning: Unchecked(value: (Double(count) / seconds, peak, baseline, count)))
                } catch { continuation.resume(throwing: error) }
            }
        }
        return result.value
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PME_VIDEO_SAMPLE"] != nil && MTLCreateSystemDefaultDevice() != nil))
    func uhdVLogThroughTheCompositor() async throws {
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PME_VIDEO_SAMPLE"]!)
        let temp = try TempDirectory()
        // Ten seconds, copied by passthrough export; the original is never touched.
        let trimmed = temp.url.appendingPathComponent("trim.mov")
        let export = try #require(AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetPassthrough))
        export.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 10, preferredTimescale: 24000))
        try await export.export(to: trimmed, as: .mov)

        var asset = MediaAsset(url: trimmed, kind: .video)
        asset.apply(await VideoMediaService.shared.metadata(for: trimmed))
        // The trim lost the camera metadata (V-Log), so keep the source's color description.
        asset.sourceColor = await VideoMediaService.shared.metadata(for: source).sourceColor
        // The passthrough trim ends with a zero-length stub sample, so count frames by duration, not samples.
        let frames = Int(try #require(asset.frameCount))
        let rate = try #require(asset.frameRate)
        let clip = TimelineClip(assetID: asset.id, frameRate: rate, durationFrames: Int64(frames))
        let service = TimelineCompositionService.shared
        let graded = goldenGradeAdjustments()
        print("COMPOSITOR sample: \(frames) frames of \(asset.sourceColor?.summary ?? "unknown color")")

        // PME_COMPOSITOR_CASE=<text> runs only the cases whose title contains it, so each can be
        // measured in a fresh process (footprints accumulate across cases in one process).
        let only = ProcessInfo.processInfo.environment["PME_COMPOSITOR_CASE"]
        // PME_VLOG_LUT adds cases with Panasonic's V-Log to V-709 as the source color.
        let vLogLUT = try ProcessInfo.processInfo.environment["PME_VLOG_LUT"].map { ResolvedLUT(hash: "throughput", lut: try CubeLUT(contentsOf: URL(fileURLWithPath: $0))) }
        func run(_ title: String, quality: MediaQuality, format: OSType, adjustments: PhotoAdjustments, proxy: URL? = nil, inputLUT: ResolvedLUT? = nil, ocio: Bool = false) async throws {
            if let only, !title.contains(only) { return }
            let result = await service.makePlayerItem(
                clips: [clip], media: [asset], adjustmentsByClipID: [clip.id: adjustments], quality: quality,
                proxyURLsByAssetID: proxy.map { [asset.id: $0] } ?? [:], renderingPath: .compositor,
                inputLUTsByAssetID: inputLUT.map { [asset.id: $0] } ?? [:],
                ocioInputsByAssetID: ocio ? [asset.id: .vLogVGamut] : [:]
            )
            #expect(result.warnings.isEmpty, "\(title): \(result.warnings)")
            let m = try await measure(try #require(result.playerItem), pixelFormat: format, frames: frames)
            print("COMPOSITOR \(title): \(m.count) frames, \(String(format: "%.1f", m.fps)) fps, app footprint \(String(format: "%.0f", m.baselineMB)) -> peak \(String(format: "%.0f", m.peakMB)) MB")
            #expect(m.count == frames, "\(title) produced \(m.count) of \(frames) frames")
        }

        // Preview quality (half-float frames), as the editor plays it.
        try await run("4K original, neutral, preview", quality: .preview, format: kCVPixelFormatType_64RGBAHalf, adjustments: .neutral)
        try await run("4K original, graded, preview", quality: .preview, format: kCVPixelFormatType_64RGBAHalf, adjustments: graded)
        // Export quality (10-bit 4:2:2 frames), as the exporter will pull them.
        try await run("4K original, neutral, export", quality: .export, format: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, adjustments: .neutral)
        try await run("4K original, graded, export", quality: .export, format: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, adjustments: graded)
        if let vLogLUT {
            try await run("4K original, V-Log LUT, preview", quality: .preview, format: kCVPixelFormatType_64RGBAHalf, adjustments: .neutral, inputLUT: vLogLUT)
            try await run("4K original, V-Log LUT, export", quality: .export, format: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, adjustments: .neutral, inputLUT: vLogLUT)
        }
        // OpenColorIO's V-Log to ACES 2.0 Rec. 709; graded clips go through Core Image in scene-linear between.
        try await run("4K original, ACES, preview", quality: .preview, format: kCVPixelFormatType_64RGBAHalf, adjustments: .neutral, ocio: true)
        try await run("4K original, ACES graded, preview", quality: .preview, format: kCVPixelFormatType_64RGBAHalf, adjustments: graded, ocio: true)
        try await run("4K original, ACES, export", quality: .export, format: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, adjustments: .neutral, ocio: true)
        // A 1080p ProRes proxy, graded, as timeline playback with proxies uses it.
        if let only, !"1080p proxy".contains(only) && !only.contains("proxy") { return }
        let proxyStart = Date()
        let proxy = try await ProxyGenerator.generate(source: trimmed, destination: temp.url.appendingPathComponent("proxy.mov")).url
        print("COMPOSITOR proxy generation: \(frames) frames in \(String(format: "%.1f", Date().timeIntervalSince(proxyStart))) s")
        try await run("1080p proxy, graded, preview", quality: .preview, format: kCVPixelFormatType_64RGBAHalf, adjustments: graded, proxy: proxy)
        try await run("1080p proxy, neutral, preview", quality: .preview, format: kCVPixelFormatType_64RGBAHalf, adjustments: .neutral, proxy: proxy)
        try await run("1080p proxy, ACES graded, preview", quality: .preview, format: kCVPixelFormatType_64RGBAHalf, adjustments: graded, proxy: proxy, ocio: true)
    }
}
