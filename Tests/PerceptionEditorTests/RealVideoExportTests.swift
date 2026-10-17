@preconcurrency import AVFoundation
import Foundation
import Metal
import Testing
@testable import PerceptionEditor

/// Gates G1 and G6 through a real export. Run in release with `--no-parallel` and
/// PME_VIDEO_SAMPLE=/Volumes/ExSSD1/Pictures/110_PANA/P1107157.MOV. G1 also needs PME_VLOG_LUT
/// (Panasonic's V-Log to V-709 `.cube`). Exports go to PME_EXPORT_DIR (default `.build/export-gate`,
/// on the same disk as the checkout) and are deleted afterwards unless PME_KEEP_EXPORT is set;
/// the originals are only read. `scripts/profile-video.sh` runs the G1 case while sampling memory (G7).
@MainActor
@Suite(.serialized)
struct RealVideoExportTests {
    private nonisolated static let environment = ProcessInfo.processInfo.environment

    private func exportFolder() throws -> URL {
        let folder = Self.environment["PME_EXPORT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".build/export-gate", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func discard(_ url: URL) {
        if Self.environment["PME_KEEP_EXPORT"] == nil { try? FileManager.default.removeItem(at: url) }
    }

    private func sample() async throws -> (MediaAsset, URL, [FileAttributeKey: Any]) {
        let source = URL(fileURLWithPath: Self.environment["PME_VIDEO_SAMPLE"]!)
        var asset = MediaAsset(url: source, kind: .video)
        asset.apply(await VideoMediaService.shared.metadata(for: source))
        return (asset, source, try FileManager.default.attributesOfItem(atPath: source.path))
    }

    /// G1: 60 s of UHD V-Log through the V-Log input transform, exported as ProRes 422 HQ at UHD,
    /// at least 38 fps. PME_EXPORT_PRESET=hevc measures HEVC Main10 instead (no gate).
    @Test(.enabled(if: environment["PME_VIDEO_SAMPLE"] != nil && environment["PME_VLOG_LUT"] != nil && MTLCreateSystemDefaultDevice() != nil))
    func uhdExportThroughput() async throws {
        let (asset, source, attributes) = try await sample()
        let rate = try #require(asset.frameRate)
        let frames = Int64(min(Double(asset.frameCount ?? 0), (60 * rate.framesPerSecond).rounded()))
        let lut = try CubeLUT(contentsOf: URL(fileURLWithPath: Self.environment["PME_VLOG_LUT"]!))
        let clip = TimelineClip(assetID: asset.id, frameRate: rate, durationFrames: frames)
        let preset: TimelineExportPreset = Self.environment["PME_EXPORT_PRESET"] == "hevc" ? .hevcMain10 : .proRes422HQ
        let destination = try exportFolder().appendingPathComponent("G1 \(preset.rawValue).mov")
        defer { discard(destination) }

        print("EXPORT G1 start: \(frames) frames, \(preset.rawValue), UHD")
        let result = try await TimelineExporter().export(
            TimelineExportJob(clips: [clip], media: [asset], inputLUTsByAssetID: [asset.id: ResolvedLUT(hash: "g1", lut: lut)]),
            settings: TimelineExportSettings(preset: preset, size: .uhd), to: destination
        )
        let fps = Double(result.frameCount) / result.seconds
        let bytes = (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
        print("EXPORT G1 \(preset.rawValue): \(result.frameCount) frames in \(String(format: "%.1f", result.seconds)) s = " +
              "\(String(format: "%.1f", fps)) fps, \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
        #expect(result.frameCount == Int(frames))
        if preset == .proRes422HQ { #expect(fps >= 38, "G1: \(fps) fps") }
        let after = try FileManager.default.attributesOfItem(atPath: source.path)
        #expect(after[.modificationDate] as? Date == attributes[.modificationDate] as? Date, "The original must never change")
    }

    /// G6 through an export: source frames 33 000–33 239 at timeline frame 0, as ProRes 422 HQ.
    @Test(.enabled(if: environment["PME_VIDEO_SAMPLE"] != nil && MTLCreateSystemDefaultDevice() != nil))
    func lateFramesOfALongClipExportExactly() async throws {
        let (asset, source, attributes) = try await sample()
        let rate = try #require(asset.frameRate)
        let firstFrame: Int64 = 33_000, count: Int64 = 240
        try #require((asset.frameCount ?? 0) >= firstFrame + count)
        let clip = TimelineClip(assetID: asset.id, frameRate: rate, sourceStartFrame: firstFrame, durationFrames: count)
        let destination = try exportFolder().appendingPathComponent("G6.mov")
        defer { discard(destination) }
        let result = try await TimelineExporter().export(
            TimelineExportJob(clips: [clip], media: [asset]), settings: TimelineExportSettings(preset: .proRes422HQ, size: .timeline), to: destination
        )
        #expect(result.frameCount == Int(count))
        #expect(try await Self.sampleCount(destination) == Int(count), "Exactly 240 frames in the file")

        // Raw 10-bit luma codes, not RGB: AVFoundation's RGB of the full-range original and of the
        // video-range export differ by about 33 dB on their own. The export is read as video-range
        // codes; the original as full-range codes (bit-exact with ffmpeg) mapped to video range.
        let exported = AVURLAsset(url: destination), original = AVURLAsset(url: source)
        var checked = 0, worst = 99.0, smallestMargin = 99.0
        for k in Array(stride(from: Int64(0), to: count, by: 10)) + [count - 1] {
            let shown = try await Self.lumaCodes(exported, at: rate.time(ofFrame: k), fullRange: false)
            var scores: [(frame: Int64, psnr: Double)] = []
            for n in max(0, firstFrame + k - 2) ... min((asset.frameCount ?? 0) - 1, firstFrame + k + 2) {
                scores.append((n, Self.psnr(shown, try await Self.lumaCodes(original, at: rate.time(ofFrame: n), fullRange: true))))
            }
            let best = try #require(scores.max { $0.psnr < $1.psnr })
            let runnerUp = scores.filter { $0.frame != best.frame }.map(\.psnr).max() ?? 0
            #expect(best.frame == firstFrame + k, "Exported frame \(k) matched source \(best.frame), wanted \(firstFrame + k)")
            #expect(best.psnr >= 45 && best.psnr - runnerUp >= 3, "Frame \(k): PSNR \(best.psnr) vs \(runnerUp)")
            worst = min(worst, best.psnr)
            smallestMargin = min(smallestMargin, best.psnr - runnerUp)
            checked += 1
        }
        print("EXPORT G6: \(checked) frames checked; worst best-match PSNR \(String(format: "%.1f", worst)) dB, " +
              "smallest margin over a neighbor \(String(format: "%.1f", smallestMargin)) dB")

        // ffmpeg's own frame 33 000 (selected by decode index, independent of timestamps) agrees with
        // exported frame 0. It decodes every earlier frame, so this takes several minutes.
        if let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            let raw = try exportFolder().appendingPathComponent("G6-ffmpeg-33000.yuv")
            defer { try? FileManager.default.removeItem(at: raw) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = ["-v", "error", "-y", "-i", source.path, "-vf", "select=eq(n\\,33000)", "-frames:v", "1",
                                 "-f", "rawvideo", "-pix_fmt", "yuv422p10le", raw.path]
            try process.run()
            process.waitUntilExit()
            let data = try Data(contentsOf: raw)
            let width = Int(try #require(asset.pixelWidth)), height = Int(try #require(asset.pixelHeight))
            try #require(data.count >= width * height * 2)
            let ffmpegCodes: [UInt16] = data.withUnsafeBytes { bytes in
                let luma = bytes.bindMemory(to: UInt16.self)
                return Self.grid(width: width, height: height).map { Self.toVideoRange(luma[$0.y * width + $0.x]) }
            }
            let agreement = Self.psnr(try await Self.lumaCodes(exported, at: .zero, fullRange: false), ffmpegCodes)
            print("EXPORT G6 ffmpeg frame 33000 vs exported frame 0: \(String(format: "%.1f", agreement)) dB")
            #expect(agreement >= 45, "ffmpeg's frame 33 000 should be exported frame 0 (\(agreement) dB)")
        } else {
            print("EXPORT G6 ffmpeg check skipped: no ffmpeg")
        }
        let after = try FileManager.default.attributesOfItem(atPath: source.path)
        #expect(after[.modificationDate] as? Date == attributes[.modificationDate] as? Date, "The original must never change")
    }

    /// Every fourth pixel in each direction, the same positions in every frame.
    private nonisolated static func grid(width: Int, height: Int) -> [(x: Int, y: Int)] {
        stride(from: 0, to: height, by: 4).flatMap { y in stride(from: 0, to: width, by: 4).map { (x: $0, y: y) } }
    }

    private nonisolated static func toVideoRange(_ fullRangeCode: UInt16) -> UInt16 {
        UInt16((64 + Double(fullRangeCode) * 876 / 1023).rounded())
    }

    /// The luma codes of the frame at `time` on the grid, in video range. A full-range source is
    /// read as `xf22` and mapped; a video-range one as `x422`.
    private nonisolated static func lumaCodes(_ asset: AVAsset, at time: CMTime, fullRange: Bool) async throws -> [UInt16] {
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: time, duration: CMTime(value: 1, timescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: fullRange
                ? kCVPixelFormatType_422YpCbCr10BiPlanarFullRange : kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
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
        return grid(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)).map {
            let code = base[$0.y * stride + $0.x] >> 6
            return fullRange ? toVideoRange(code) : code
        }
    }

    /// PSNR of 10-bit codes against the full 1023 scale.
    private nonisolated static func psnr(_ a: [UInt16], _ b: [UInt16]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let mse = zip(a, b).reduce(0.0) { $0 + pow(Double($1.0) - Double($1.1), 2) } / Double(a.count)
        return mse == 0 ? 99 : 10 * log10(1023 * 1023 / mse)
    }

    private nonisolated static func sampleCount(_ url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        var count = 0
        while let sample = output.copyNextSampleBuffer() { count += CMSampleBufferGetNumSamples(sample) }
        return count
    }
}
