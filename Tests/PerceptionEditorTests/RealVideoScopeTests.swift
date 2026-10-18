@preconcurrency import AVFoundation
import Foundation
import Metal
import Testing
@testable import PerceptionEditor

/// Gate G9 on real V-Log. Run with PME_VLOG_SHORT=/Volumes/ExSSD1/Pictures/110_PANA/P1107158.MOV,
/// in release and with `--no-parallel`. With no input transform the scopes show the code values as
/// recorded, so the first frame's waveform must agree with its own luma plane (read as `xf22`, bit-exact
/// with ffmpeg). Frames are pulled at the clip's own rate, as playback would.
@MainActor
@Suite(.serialized)
struct RealVideoScopeTests {
    private struct Unchecked<Value>: @unchecked Sendable { let value: Value }

    private final class Collector: @unchecked Sendable {
        let lock = NSLock()
        var times: [TimeInterval] = []
        var gpu: [Double] = []
        var last: ScopeAnalysis?
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PME_VLOG_SHORT"] != nil && MTLCreateSystemDefaultDevice() != nil))
    func scopesOfRealVLogAsRecorded() async throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PME_VLOG_SHORT"]!)
        var asset = MediaAsset(url: url, kind: .video)
        asset.apply(await VideoMediaService.shared.metadata(for: url))
        let rate = try #require(asset.frameRate)
        let frames = min(Int(try #require(asset.frameCount)), Int(rate.nearestFrame(toSeconds: 5)))
        let clip = TimelineClip(assetID: asset.id, frameRate: rate, durationFrames: Int64(frames))
        let item = try #require(await TimelineCompositionService.shared.makePlayerItem(
            clips: [clip], media: [asset], quality: .preview, renderingPath: .compositor
        ).playerItem)
        let tracks = Unchecked(value: try await item.asset.loadTracks(withMediaType: .video))
        let renderSize = item.videoComposition?.renderSize ?? .zero

        let tap = ScopeTap.shared
        let renderer = try ScopeRenderer()
        let worker = ScopeWorker() // The scope panel's own worker.
        let collector = Collector()
        tap.setListener { texture in
            worker.analyze(texture) { analysis in
                collector.lock.withLock {
                    collector.times.append(ProcessInfo.processInfo.systemUptime)
                    collector.gpu.append(analysis.gpuMilliseconds)
                    collector.last = analysis
                }
            }
        }
        tap.source = .output
        tap.isEnabled = true
        defer { tap.isEnabled = false; tap.setListener(nil) }

        let job = Unchecked(value: (asset: item.asset, composition: item.videoComposition))
        let frameSeconds = 1 / rate.framesPerSecond
        let pulled: Int = try await Task.detached {
            let reader = try AVAssetReader(asset: job.value.asset)
            let output = AVAssetReaderVideoCompositionOutput(videoTracks: tracks.value, videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf
            ])
            output.videoComposition = job.value.composition
            output.alwaysCopiesSampleData = false
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
            let start = ProcessInfo.processInfo.systemUptime
            var count = 0
            while output.copyNextSampleBuffer() != nil {
                count += 1
                // Real-time pacing: frame k is due at k / rate.
                let due = start + Double(count) * frameSeconds
                let wait = due - ProcessInfo.processInfo.systemUptime
                if wait > 0 { usleep(UInt32(wait * 1_000_000)) }
            }
            return count
        }.value
        try await Task.sleep(for: .milliseconds(300))

        let (times, gpu, last) = collector.lock.withLock { (collector.times, collector.gpu, collector.last) }
        let analysis = try #require(last)
        let span = (times.last ?? 0) - (times.first ?? 0)
        let rateHz = times.count > 1 ? Double(times.count - 1) / span : 0
        let medianGPU = gpu.sorted()[gpu.count / 2]
        let p99GPU = gpu.sorted()[min(gpu.count - 1, gpu.count * 99 / 100)]

        // The compositor's own scope cost: a 4×4-tap downsample of a frame of the render size, and of 1080p.
        let downsample = try Self.downsampleMilliseconds(width: Int(renderSize.width), height: Int(renderSize.height))
        let downsample1080 = try Self.downsampleMilliseconds(width: 1920, height: 1080)
        print("SCOPES G9 playback: \(pulled) frames at \(Int(renderSize.width))x\(Int(renderSize.height)), " +
              "\(times.count) updates, \(String(format: "%.1f", rateHz)) Hz; analysis GPU median " +
              "\(String(format: "%.2f", medianGPU)) ms, downsample \(String(format: "%.2f", downsample)) ms " +
              "(1080p \(String(format: "%.2f", downsample1080)) ms); analysis p99 \(String(format: "%.2f", p99GPU)) ms; " +
              "per-update total at 1080p: median \(String(format: "%.2f", medianGPU + downsample1080)) ms, " +
              "p99 \(String(format: "%.2f", p99GPU + downsample1080)) ms")
        #expect(pulled == frames)
        #expect(rateHz >= 10, "Scope updates at \(rateHz) Hz")
        #expect(medianGPU + downsample1080 <= 2, "Scope GPU cost at 1080p \(medianGPU + downsample1080) ms")

        // The first frame alone, captured and analyzed, against its own luma plane.
        tap.setListener(nil)
        tap.minimumInterval = 0
        defer { tap.minimumInterval = 1.0 / 20 }
        let published = tap.publishedCount
        try await Task.detached {
            let reader = try AVAssetReader(asset: job.value.asset)
            reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: frameSeconds, preferredTimescale: 600_000))
            let output = AVAssetReaderVideoCompositionOutput(videoTracks: tracks.value, videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf
            ])
            output.videoComposition = job.value.composition
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
            _ = output.copyNextSampleBuffer()
            reader.cancelReading()
        }.value
        try await waitUntil { tap.publishedCount > published }
        let firstFrame = Unchecked(value: try #require(tap.latest))
        let first = try await Task.detached { Unchecked(value: try renderer.analyze(firstFrame.value, mode: .luma)) }.value.value
        var histogram = [Int](repeating: 0, count: first.bins)
        for column in 0 ..< first.columns {
            for bin in 0 ..< first.bins { histogram[bin] += Int(first.waveform[column * first.bins + bin]) }
        }
        let scope = Self.statistics(histogram)
        let plane = try await Self.lumaPlaneStatistics(url)
        print("SCOPES G9 first frame: scope mean \(String(format: "%.1f", scope.mean)) p10 \(scope.p10) p90 \(scope.p90) min \(scope.min); " +
              "luma plane mean \(String(format: "%.1f", plane.mean)) p10 \(plane.p10) p90 \(plane.p90) min \(plane.min)")
        #expect(abs(scope.mean - plane.mean) <= 1.5, "The waveform's mean code is the frame's")
        #expect(abs(scope.p10 - plane.p10) <= 6 && abs(scope.p90 - plane.p90) <= 6, "Low and high codes agree within the downsample's smoothing")
        // V-Log black is code 128: as recorded, nothing but noise falls below it.
        #expect(scope.min >= 96, "Darkest scope code \(scope.min)")
    }

    private struct Statistics { var mean: Double; var p10: Int; var p90: Int; var min: Int }

    private nonisolated static func statistics(_ histogram: [Int]) -> Statistics {
        let total = histogram.reduce(0, +)
        var sum = 0, weighted = 0.0
        var p10 = -1, p90 = -1, low = -1
        for (code, count) in histogram.enumerated() {
            if count > 0, low < 0 { low = code }
            sum += count
            weighted += Double(code) * Double(count)
            if p10 < 0, Double(sum) >= 0.1 * Double(total) { p10 = code }
            if p90 < 0, Double(sum) >= 0.9 * Double(total) { p90 = code }
        }
        return Statistics(mean: weighted / Double(total), p10: p10, p90: p90, min: low)
    }

    /// The first frame's luma code values, read as full-range 10-bit 4:2:2.
    private nonisolated static func lumaPlaneStatistics(_ url: URL) async throws -> Statistics {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_422YpCbCr10BiPlanarFullRange
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        let sample = try #require(output.copyNextSampleBuffer())
        reader.cancelReading()
        let buffer = try #require(CMSampleBufferGetImageBuffer(sample))
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(to: UInt16.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) / 2
        var histogram = [Int](repeating: 0, count: 1024)
        for y in 0 ..< CVPixelBufferGetHeightOfPlane(buffer, 0) {
            for x in 0 ..< CVPixelBufferGetWidthOfPlane(buffer, 0) { histogram[Int(base[y * stride + x] >> 6)] += 1 }
        }
        return statistics(histogram)
    }

    /// Median GPU time of the compositor's scope downsample from a frame of the render size.
    private nonisolated static func downsampleMilliseconds(width: Int, height: Int) throws -> Double {
        let kernels = try VideoColorKernels()
        let source = try kernels.makeWorkingTexture(width: width, height: height)
        let target = try kernels.makeWorkingTexture(width: 512, height: max(1, 512 * height / width))
        var times: [Double] = []
        for _ in 0 ..< 11 {
            let commandBuffer = try #require(kernels.runtime.queue.makeCommandBuffer())
            try kernels.downsampleForScope(source, into: target, commandBuffer: commandBuffer)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            times.append((commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1000)
        }
        return times.sorted()[5]
    }
}
