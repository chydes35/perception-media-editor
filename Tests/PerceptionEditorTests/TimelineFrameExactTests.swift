@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import PerceptionEditor

/// Edit points must land on exact frames at 24000/1001. With Double seconds converted at timescale
/// 600 (one 23.976 frame is 25.025 ticks), a cut whose source and timeline positions round
/// differently started a fraction of a tick early, so the player showed the previous source frame:
/// 55 of the 240 output frames in `shuffledCutsShowExactlyTheirFrames` before schema 11.
/// Serialized for the same reason as `TimelineVideoCompositorTests`: each test decodes hundreds of frames.
@MainActor
@Suite(.serialized)
struct TimelineFrameExactTests {
    private func clips(_ ranges: [(start: Int, count: Int)], asset: MediaAsset) -> [TimelineClip] {
        var cursor: Int64 = 0
        return ranges.map { range in
            defer { cursor += Int64(range.count) }
            return TimelineClip(
                assetID: asset.id,
                timelineStartFrame: cursor,
                sourceStartFrame: Int64(range.start),
                durationFrames: Int64(range.count)
            )
        }
    }

    private func shownFrames(for ranges: [(start: Int, count: Int)]) async throws -> (expected: [Int], shown: [Int]) {
        let temp = try TempDirectory()
        let movie = try await writeFrameNumberedMovie(to: temp.url.appendingPathComponent("numbers.mov"), frames: 240)
        let asset = MediaAsset(url: movie, kind: .video, durationSeconds: 240 * 1001 / 24000.0, frameRate: .ntsc23976, frameCount: 240)
        let result = await TimelineCompositionService.shared.makePlayerItem(
            clips: clips(ranges, asset: asset), media: [asset], quality: .export
        )
        let item = try #require(result.playerItem)
        let expected = ranges.flatMap { range in (0 ..< range.count).map { range.start + $0 } }
        return (expected, try await shownFrameNumbers(item, frames: expected.count))
    }

    @Test func shuffledCutsShowExactlyTheirFrames() async throws {
        // Every cut moves the source to a different offset from the timeline.
        var ranges: [(start: Int, count: Int)] = (0 ..< 120).map { ((($0 * 37) + 11) % 240, 1) }
        ranges += [(5, 60), (133, 60)]
        let (expected, shown) = try await shownFrames(for: ranges)
        let wrong = zip(expected, shown).enumerated().filter { $0.element.0 != $0.element.1 }
        #expect(wrong.isEmpty, "Output frames (index, wanted, shown): \(wrong.prefix(12).map { ($0.offset, $0.element.0, $0.element.1) })")
    }

    @Test func singleFrameClipsInARowPlayEveryFrame() async throws {
        var ranges: [(start: Int, count: Int)] = [(0, 117)]
        for frame in 117 ..< 147 { ranges.append((frame, 1)) }
        ranges.append((147, 93))
        let (expected, shown) = try await shownFrames(for: ranges)
        #expect(shown == expected)
    }

    /// Task 13.2b: an iPhone clip (24 fps, time base 1/600) had one 26/600 s frame, so every later
    /// frame was 1/600 s late and every cut after it showed the previous source frame. The fixture
    /// makes frames 100 onwards one tick late; both the native and the compositor path must show
    /// exactly the chosen frames, and cutting up to the source's last frame must still work.
    @Test(arguments: [TimelineRenderingPath.automatic, .compositor])
    func lateTimestampsStillShowTheirOwnFrames(path: TimelineRenderingPath) async throws {
        let temp = try TempDirectory()
        let rate = FrameRate(frameDuration: 25, timescale: 600)
        let movie = try await writeFrameNumberedMovie(to: temp.url.appendingPathComponent("late.mov"), frames: 200, rate: rate, lateFrom: 100)
        let asset = MediaAsset(url: movie, kind: .video, durationSeconds: 200 / 24.0, frameRate: rate, frameCount: 200)
        let ranges: [(start: Int, count: Int)] = [(90, 20), (150, 5), (40, 3), (120, 30), (195, 5)]
        var cursor: Int64 = 0
        let timeline = ranges.map { range -> TimelineClip in
            defer { cursor += Int64(range.count) }
            return TimelineClip(assetID: asset.id, frameRate: rate, timelineStartFrame: cursor, sourceStartFrame: Int64(range.start), durationFrames: Int64(range.count))
        }
        let result = await TimelineCompositionService.shared.makePlayerItem(
            clips: timeline, media: [asset], quality: .export, sequenceFrameRate: rate, renderingPath: path
        )
        #expect(result.warnings.isEmpty, "\(result.warnings)")
        let item = try #require(result.playerItem)
        let expected = ranges.flatMap { range in (0 ..< range.count).map { range.start + $0 } }
        let shown = try await shownFrameNumbers(item, frames: expected.count, frameDuration: rate.frameTime)
        let wrong = zip(expected, shown).enumerated().filter { $0.element.0 != $0.element.1 }
        #expect(wrong.isEmpty, "Output frames (index, wanted, shown): \(wrong.prefix(12).map { ($0.offset, $0.element.0, $0.element.1) })")
    }

    @Test func compositionTimesAreWholeFrames() async throws {
        let (_, shown) = try await shownFrames(for: [(10, 30), (200, 20)])
        #expect(shown == Array(10 ..< 40) + Array(200 ..< 220))
    }
}
