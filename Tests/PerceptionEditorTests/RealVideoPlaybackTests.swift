@preconcurrency import AVFoundation
import Foundation
import Metal
import QuartzCore
import Testing
@testable import PerceptionEditor

/// Gates G1 (playback part) and G7 (playback part): a 1080p proxy of real V-Log, graded with the
/// golden grade (HSL and curves included), with V-Log source color and the scopes on, played in
/// real time by AVPlayer, several times over. Run in release with `--no-parallel`:
///   PME_VIDEO_SAMPLE=/Volumes/ExSSD1/Pictures/110_PANA/P1107157.MOV
/// Optional: PME_VLOG_LUT=<Panasonic .cube> (source color through the LUT; ACES otherwise),
/// PME_PLAYBACK_SECONDS (60), PME_PLAYBACK_REPEATS (10). `scripts/profile-video.sh` with
/// PME_PROFILE=playback runs it and adds the decoder process to the footprint.
///
/// AVPlayer's own dropped-frame count needs a display, so drops are counted here: a frame of the
/// clip that the video output never delivered while playing in real time was dropped.
@MainActor
@Suite(.serialized)
struct RealVideoPlaybackTests {
    private struct Unchecked<Value>: @unchecked Sendable { let value: Value }

    private final class Delivered: @unchecked Sendable {
        let lock = NSLock()
        var frames: Set<Int64> = []
        var scopeUpdates: [TimeInterval] = []
    }

    nonisolated static let environment = ProcessInfo.processInfo.environment

    @Test(.enabled(if: environment["PME_VIDEO_SAMPLE"] != nil && MTLCreateSystemDefaultDevice() != nil))
    func proxyPlaybackWithGradeSourceColorAndScopes() async throws {
        let source = URL(fileURLWithPath: Self.environment["PME_VIDEO_SAMPLE"]!)
        let seconds = Double(Self.environment["PME_PLAYBACK_SECONDS"] ?? "") ?? 60
        let repeats = Int(Self.environment["PME_PLAYBACK_REPEATS"] ?? "") ?? 10
        let temp = try TempDirectory()

        // A trim copied by passthrough export, and its 1080p proxy; the original is never touched.
        let trimmed = temp.url.appendingPathComponent("trim.mov")
        let export = try #require(AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetPassthrough))
        export.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 24000))
        try await export.export(to: trimmed, as: .mov)
        var asset = MediaAsset(url: trimmed, kind: .video)
        asset.apply(await VideoMediaService.shared.metadata(for: trimmed))
        asset.sourceColor = await VideoMediaService.shared.metadata(for: source).sourceColor
        let rate = try #require(asset.frameRate)
        let frames = Int(try #require(asset.frameCount))
        let proxy = try await ProxyGenerator.generate(source: trimmed, destination: temp.url.appendingPathComponent("proxy.mov")).url
        let clip = TimelineClip(assetID: asset.id, frameRate: rate, durationFrames: Int64(frames))

        let lut = try Self.environment["PME_VLOG_LUT"].map { ResolvedLUT(hash: "playback", lut: try CubeLUT(contentsOf: URL(fileURLWithPath: $0))) }
        let sourceColor = lut == nil ? "ACES" : "V-Log LUT"
        print("PLAYBACK sample: \(frames) frames (\(seconds) s) of \(asset.sourceColor?.summary ?? "unknown"), 1080p proxy, golden grade, \(sourceColor), scopes on, \(repeats) runs")

        let delivered = Delivered()
        let worker = ScopeWorker()
        let tap = ScopeTap.shared
        tap.setListener { texture in
            worker.analyze(texture) { _ in delivered.lock.withLock { delivered.scopeUpdates.append(CACurrentMediaTime()) } }
        }
        tap.source = .output
        tap.isEnabled = true
        defer { tap.isEnabled = false; tap.setListener(nil) }

        // Tells scripts/profile-video.sh that setup (trim, proxy generation) is over and playback starts.
        if let marker = Self.environment["PME_PROFILE_MARKER"] { FileManager.default.createFile(atPath: marker, contents: nil) }
        let key = UUID()
        var footprints: [Double] = []
        var missingPerRun: [Int] = []
        for run in 1 ... repeats {
            let result = await TimelineCompositionService.shared.makePlayerItem(
                clips: [clip], media: [asset], adjustmentsByClipID: [clip.id: goldenGradeAdjustments()], quality: .preview,
                proxyURLsByAssetID: [asset.id: proxy], renderingPath: .compositor, statisticsKey: key,
                inputLUTsByAssetID: lut.map { [asset.id: $0] } ?? [:],
                ocioInputsByAssetID: lut == nil ? [asset.id: .vLogVGamut] : [:]
            )
            #expect(result.warnings.isEmpty, "\(result.warnings)")
            let item = try #require(result.playerItem)
            delivered.lock.withLock { delivered.frames.removeAll() }
            let wall = try await Self.play(item, rate: rate, into: delivered)
            let count = delivered.lock.withLock { delivered.frames.count }
            let missing = frames - count
            missingPerRun.append(missing)
            footprints.append(Self.footprintMB())
            print(String(format: "PLAYBACK run %d: %d of %d frames delivered in %.1f s, app footprint %.0f MB", run, count, frames, wall, footprints.last!))
        }

        let statistics = TimelineVideoCompositor.statistics(for: key)
        let gpu = statistics.gpuMilliseconds.sorted()
        let p99 = gpu.isEmpty ? .infinity : gpu[min(gpu.count - 1, Int(Double(gpu.count) * 0.99))]
        let updates = delivered.lock.withLock { delivered.scopeUpdates }
        let scopeHz = Double(updates.count) / (Double(repeats) * seconds)
        let growth = (footprints.last ?? 0) - (footprints.first ?? 0)
        print(String(format: "PLAYBACK G1: missing frames per run %@; compositor %@; GPU p99 %.2f ms", missingPerRun.description, statistics.description, p99))
        print(String(format: "PLAYBACK G7 (app only): footprint after run 1 %.0f MB, after run %d %.0f MB, growth %.1f MB; scopes %.1f Hz", footprints.first ?? 0, repeats, footprints.last ?? 0, growth, scopeHz))
        #expect(missingPerRun.allSatisfy { $0 == 0 }, "Frames dropped: \(missingPerRun)")
        #expect(p99 <= 12, "GPU time p99 \(p99) ms")
        #expect(growth <= 20, "Footprint grew \(growth) MB over \(repeats) runs")
        #expect(scopeHz >= 10, "Scopes updated at \(scopeHz) Hz")
    }

    /// Plays `item` from the start in real time, pulling each new frame from a video output at
    /// 120 Hz (a display would pull at its refresh rate), until the end. Returns the wall time.
    private static func play(_ item: AVPlayerItem, rate: FrameRate, into delivered: Delivered) async throws -> Double {
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        try await waitUntil(timeout: 30) { item.status == .readyToPlay }
        let duration = item.duration.seconds
        let frameDuration = rate.frameTime
        let timer = pullFrames(from: output, frameDuration: frameDuration, into: delivered)
        let start = CACurrentMediaTime()
        player.play()
        try await waitUntil(timeout: duration + 30) { player.currentTime().seconds >= duration - frameDuration.seconds / 2 || item.status == .failed }
        try await Task.sleep(for: .milliseconds(200)) // Let the output hand over the last frame.
        timer.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        #expect(item.status != .failed, "\(String(describing: item.error))")
        return CACurrentMediaTime() - start
    }

    /// Pulls each new frame on a background queue at 120 Hz, recording which frame of the clip it is.
    /// Nonisolated, so the handler does not inherit the main actor and trap on the timer's queue.
    private nonisolated static func pullFrames(from output: AVPlayerItemVideoOutput, frameDuration: CMTime, into delivered: Delivered) -> any DispatchSourceTimer {
        let box = Unchecked(value: output)
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "PerceptionEditorTests.playback", qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: .microseconds(8333), leeway: .microseconds(500))
        timer.setEventHandler {
            let output = box.value
            let time = output.itemTime(forHostTime: CACurrentMediaTime())
            guard output.hasNewPixelBuffer(forItemTime: time) else { return }
            var shown = CMTime.zero
            if output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &shown) != nil {
                let index = Int64((shown.seconds / frameDuration.seconds).rounded())
                delivered.lock.withLock { _ = delivered.frames.insert(index) }
            }
        }
        timer.resume()
        return timer
    }

    private nonisolated static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return status == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}
