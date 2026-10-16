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

    @Test func compositionTimesAreWholeFrames() async throws {
        let (_, shown) = try await shownFrames(for: [(10, 30), (200, 20)])
        #expect(shown == Array(10 ..< 40) + Array(200 ..< 220))
    }
}
