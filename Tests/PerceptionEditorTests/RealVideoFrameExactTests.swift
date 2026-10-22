@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import PerceptionEditor

/// Gate G6 on the composition (export through it arrives with Task 8). Run with
/// PME_VIDEO_SAMPLE=/Volumes/ExSSD1/Pictures/110_PANA/P1107157.MOV (33 240 frames at 23.976).
@MainActor
struct RealVideoFrameExactTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PME_VIDEO_SAMPLE"] != nil))
    func lateFramesOfALongClipLandExactly() async throws {
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PME_VIDEO_SAMPLE"]!)
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        var asset = MediaAsset(url: source, kind: .video)
        asset.apply(await VideoMediaService.shared.metadata(for: source))
        let rate = try #require(asset.frameRate)
        #expect(rate == .ntsc23976)
        let firstFrame: Int64 = 33_000, count: Int64 = 240
        try #require((asset.frameCount ?? 0) >= firstFrame + count)

        let clip = TimelineClip(assetID: asset.id, frameRate: rate, sourceStartFrame: firstFrame, durationFrames: count)
        let result = await TimelineCompositionService.shared.makePlayerItem(clips: [clip], media: [asset], quality: .export)
        let item = try #require(result.playerItem)
        #expect(result.durationSeconds == rate.seconds(ofFrames: count))

        let timeline = imageGenerator(item.asset)
        let original = imageGenerator(AVURLAsset(url: source))
        var checked = 0
        for k in Array(stride(from: Int64(0), to: count, by: 10)) + [count - 1] {
            let shown = try await luma(timeline, at: rate.time(ofFrame: k))
            var scores: [(frame: Int64, psnr: Double)] = []
            let lastSourceFrame = (asset.frameCount ?? 0) - 1
            for n in max(0, firstFrame + k - 2) ... min(lastSourceFrame, firstFrame + k + 2) {
                scores.append((n, psnr(shown, try await luma(original, at: rate.time(ofFrame: n)))))
            }
            let best = try #require(scores.max { $0.psnr < $1.psnr })
            let runnerUp = scores.filter { $0.frame != best.frame }.map(\.psnr).max() ?? 0
            #expect(best.frame == firstFrame + k, "Timeline frame \(k) matched source \(best.frame), wanted \(firstFrame + k)")
            #expect(best.psnr >= 45 && best.psnr - runnerUp >= 3, "Frame \(k): PSNR \(best.psnr) vs \(runnerUp)")
            checked += 1
        }
        print("G6 composition: \(checked) frames checked between source frames \(firstFrame) and \(firstFrame + count - 1)")
        let after = try FileManager.default.attributesOfItem(atPath: source.path)
        #expect(after[.modificationDate] as? Date == attributes[.modificationDate] as? Date, "The original must never change")
    }

    /// Gate G6, iPhone case (Task 13.2b). `IMG_0001` has one 26/600 s frame at 8.877 s (decode index
    /// 213), which leaves every later frame 1/600 s behind the 24 fps grid. Cuts on both sides of it
    /// must show their own source frames. Run with
    /// PME_APPLELOG_SHORT=/Volumes/ExSSD1/PMVideoTestFiles/IMG_0001.MOV.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PME_APPLELOG_SHORT"] != nil))
    func iPhoneCutsAfterAnIrregularFrameLandExactly() async throws {
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PME_APPLELOG_SHORT"]!)
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        var asset = MediaAsset(url: source, kind: .video)
        asset.apply(await VideoMediaService.shared.metadata(for: source))
        let rate = try #require(asset.frameRate)

        // Each source frame's real presentation time, by decode index (asking at n / 24 is the bug).
        let sourceAsset = AVURLAsset(url: source)
        let track = try #require(try await sourceAsset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: sourceAsset)
        let samples = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        samples.alwaysCopiesSampleData = false
        reader.add(samples)
        #expect(reader.startReading())
        var times: [CMTime] = []
        while let sample = samples.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0 { times.append(sample.presentationTimeStamp) }
        }
        let late = times.indices.filter { times[$0] != rate.time(ofFrame: Int64($0), origin: times[0]) }
        print("iPhone G6: \(times.count) frames at \(rate), \(late.count) off the grid from index \(late.first ?? -1)")
        try #require(!late.isEmpty, "This clip should have frames off the grid")

        let ranges: [(start: Int64, count: Int64)] = [(300, 12), (205, 15), (600, 8)]
        var cursor: Int64 = 0
        let clips = ranges.map { range -> TimelineClip in
            defer { cursor += range.count }
            return TimelineClip(assetID: asset.id, frameRate: rate, timelineStartFrame: cursor, sourceStartFrame: range.start, durationFrames: range.count)
        }
        let result = await TimelineCompositionService.shared.makePlayerItem(clips: clips, media: [asset], quality: .export)
        let item = try #require(result.playerItem)

        let timeline = imageGenerator(item.asset)
        let original = imageGenerator(sourceAsset)
        var checked = 0, wrong: [(Int64, Int64, Int64)] = []
        var timelineFrame: Int64 = 0
        for range in ranges {
            for offset in 0 ..< range.count {
                defer { timelineFrame += 1 }
                let wanted = range.start + offset
                let shown = try await luma(timeline, at: rate.time(ofFrame: timelineFrame))
                var scores: [(frame: Int64, psnr: Double)] = []
                for n in max(0, wanted - 2) ... min(Int64(times.count - 1), wanted + 2) {
                    scores.append((n, psnr(shown, try await luma(original, at: times[Int(n)]))))
                }
                let best = try #require(scores.max { $0.psnr < $1.psnr })
                if best.frame != wanted { wrong.append((timelineFrame, wanted, best.frame)) }
                checked += 1
            }
        }
        print("iPhone G6: \(checked) timeline frames checked, \(wrong.count) wrong")
        #expect(wrong.isEmpty, "(timeline frame, wanted, shown): \(wrong.prefix(12))")
        let after = try FileManager.default.attributesOfItem(atPath: source.path)
        #expect(after[.modificationDate] as? Date == attributes[.modificationDate] as? Date, "The original must never change")
    }

    private func imageGenerator(_ asset: AVAsset) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 480, height: 270)
        return generator
    }

    private func luma(_ generator: AVAssetImageGenerator, at time: CMTime) async throws -> [UInt8] {
        let image = try await generator.image(at: time).image
        var gray = [UInt8](repeating: 0, count: image.width * image.height)
        let context = try #require(CGContext(
            data: &gray, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return gray
    }

    private func psnr(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let mse = zip(a, b).reduce(0.0) { $0 + pow(Double($1.0) - Double($1.1), 2) } / Double(a.count)
        return mse == 0 ? 99 : 10 * log10(255 * 255 / mse)
    }
}
