import CoreGraphics
import Foundation
import Testing
@testable import PerceptionEditor

/// Deterministic stand-in: the object is a disc around the first include click, at three radii.
struct FakeSegmenter: PromptableSegmenter {
    func prepare(photoID: UUID, image: CGImage) async throws {}
    func candidates(photoID: UUID, points: [SegmentationPoint]) async throws -> [SegmentationCandidate] {
        guard let click = points.first(where: \.include) else { throw SegmentationError.noPoints }
        return [0.30, 0.05, 0.15].enumerated().map { index, radius in
            let side = 64
            var logits = [Float](repeating: -4, count: side * side)
            for y in 0 ..< side {
                for x in 0 ..< side {
                    let dx = (Double(x) + 0.5) / Double(side) - click.x, dy = (Double(y) + 0.5) / Double(side) - click.y
                    if (dx * dx + dy * dy).squareRoot() < radius { logits[y * side + x] = 4 }
                }
            }
            return SegmentationCandidate(score: Float(index), width: side, height: side, logits: logits)
        }
    }
    func unload() async {}
}

struct PromptableSegmenterTests {
    @Test func clicksMapToTheModelsSquareInputAndLabels() {
        let points = [SegmentationPoint(x: 0.5, y: 0.25, include: true), SegmentationPoint(x: 1.4, y: -0.2, include: false)]
        let mapped = SegmentationPostprocessing.modelPoints(points)
        #expect(mapped.map(\.x) == [512, 1024])
        #expect(mapped.map(\.y) == [256, 0])
        #expect(mapped.map(\.label) == [1, 0])
    }

    @Test func tooManyClicksKeepTheMostRecentSixteen() {
        let points = (0 ..< 20).map { SegmentationPoint(x: Double($0) / 20, y: 0.5, include: true) }
        let mapped = SegmentationPostprocessing.modelPoints(points)
        #expect(mapped.count == 16)
        #expect(mapped.first?.x == Float(4.0 / 20 * 1024))
    }

    @Test func candidatesAreOrderedFromPartToWhole() async throws {
        let fake = FakeSegmenter()
        let ordered = SegmentationPostprocessing.orderedByArea(
            try await fake.candidates(photoID: UUID(), points: [SegmentationPoint(x: 0.5, y: 0.5, include: true)]))
        #expect(ordered.map(\.insideCount) == ordered.map(\.insideCount).sorted())
        #expect(ordered.map(\.score) == [1, 2, 0])
    }

    @Test func maskIsUpsampledBeforeItIsThresholded() {
        // Logits fall from +2 to -2 across four columns; the zero crossing must land mid-way at any size.
        let candidate = SegmentationCandidate(score: 1, width: 4, height: 1, logits: [2, 2, -2, -2])
        let pixels = SegmentationPostprocessing.maskPixels(candidate, width: 16, height: 2)
        #expect(pixels.count == 32)
        let row = Array(pixels[0 ..< 16])
        #expect(row.prefix(8).allSatisfy { $0 == 255 })
        #expect(row.suffix(8).allSatisfy { $0 == 0 })
    }

    @Test func malformedCandidatesGiveNoMask() {
        let broken = SegmentationCandidate(score: 0, width: 4, height: 4, logits: [1, 2, 3])
        #expect(SegmentationPostprocessing.maskPixels(broken, width: 8, height: 8).isEmpty)
    }

    @Test func cacheKeepsOnlyTheMostRecentlyUsedPhotos() {
        var cache = RecentlyUsedCache<Int, String>(capacity: 2)
        cache.insert("a", for: 1)
        cache.insert("b", for: 2)
        _ = cache.value(for: 1)
        cache.insert("c", for: 3)
        #expect(cache.value(for: 2) == nil)
        #expect(cache.value(for: 1) == "a")
        #expect(cache.value(for: 3) == "c")
        cache.removeAll()
        #expect(cache.keys.isEmpty)
    }

    @Test func missingModelsAreReportedByName() async {
        let segmenter = SAM2Segmenter(directory: URL(fileURLWithPath: "/nonexistent-models"))
        let image = try! #require(Self.disc(side: 64, center: 0.5, radius: 0.2))
        await #expect(throws: SegmentationError.missingModel) {
            try await segmenter.prepare(photoID: UUID(), image: image)
        }
    }

    /// Opt-in: PM_SAM_MODELS=<folder with the three SAM2*.mlmodelc> (scripts/prepare-sam-model.sh makes them).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PM_SAM_MODELS"] != nil))
    func realModelSelectsTheDiscUnderTheClick() async throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["PM_SAM_MODELS"]))
        let segmenter = SAM2Segmenter(directory: directory)
        let image = try #require(Self.disc(side: 512, center: 0.5, radius: 0.25))
        let id = UUID()
        let start = ContinuousClock.now
        try await segmenter.prepare(photoID: id, image: image)
        let encode = ContinuousClock.now - start
        let candidates = try await segmenter.candidates(photoID: id, points: [SegmentationPoint(x: 0.5, y: 0.5, include: true)])
        #expect(candidates.count == 3)
        let sizes = candidates.map(\.insideCount)
        #expect(sizes == sizes.sorted())
        // Some candidate covers the disc and stays well inside the frame.
        let covering = candidates.contains { candidate in
            let mask = SegmentationPostprocessing.maskPixels(candidate, width: 128, height: 128)
            return mask[64 * 128 + 64] == 255 && mask[2 * 128 + 2] == 0
        }
        #expect(covering)
        print("SAM2 encode \(encode), \(sizes) pixels inside")
        await segmenter.unload()
    }

    private static func disc(side: Int, center: Double, radius: Double) -> CGImage? {
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.setFillColor(CGColor(red: 0.95, green: 0.8, blue: 0.2, alpha: 1))
        let d = Double(side) * radius * 2
        context.fillEllipse(in: CGRect(x: Double(side) * center - d / 2, y: Double(side) * center - d / 2, width: d, height: d))
        return context.makeImage()
    }
}
