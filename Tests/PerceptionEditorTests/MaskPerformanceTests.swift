import Foundation
import Testing
@testable import PerceptionEditor

/// Opt in and filter to this suite so real RAW/export work cannot compete with its timings.
@Suite(.serialized)
struct MaskPerformanceTests {
    private static var enabled: Bool {
        ProcessInfo.processInfo.environment["PME_RUN_MASK_BENCHMARKS"] == "1"
    }

    private func strokes(_ count: Int, spacing: Double = 0.01, thirdPoint: Bool = false) -> [BrushStroke] {
        (0 ..< count).map { index in
            var points = [
                NormalizedPoint(x: 0.1 + Double(index) * spacing, y: 0.3),
                NormalizedPoint(x: 0.2 + Double(index) * spacing, y: 0.7)
            ]
            if thirdPoint { points.append(NormalizedPoint(x: 0.3 + Double(index) * spacing, y: 0.4)) }
            return BrushStroke(points: points, size: thirdPoint ? 0.06 : 0.05, feather: 0.6)
        }
    }

    @Test(.enabled(if: Self.enabled))
    func initialRasterAndExactCacheReuse() throws {
        let strokes = strokes(40, spacing: 0.02)
        let cache = BrushMaskCache()
        let clock = ContinuousClock()
        let start = clock.now
        let image = try #require(BrushRasterizer.raster(strokes, width: 2560, height: 1707, cache: cache))
        let first = start.duration(to: clock.now)
        let cachedStart = clock.now
        let cached = try #require(BrushRasterizer.raster(strokes, width: 2560, height: 1707, cache: cache))
        let reuse = cachedStart.duration(to: clock.now)
        #expect(cached === image)
        #expect(first < .seconds(2), "Initial 40-stroke raster: \(first)")
        #expect(reuse < .milliseconds(50), "Exact cache lookup: \(reuse)")
        print("Mask benchmark: initial=\(first), cached=\(reuse)")
    }

    @Test(.enabled(if: Self.enabled))
    func addingPointsToALargeMask() throws {
        let strokes = strokes(60, thirdPoint: true)
        let cache = BrushMaskCache()
        var growing = BrushStroke(points: [NormalizedPoint(x: 0.3, y: 0.5)], size: 0.08, feather: 0.5)
        _ = try #require(BrushRasterizer.raster(strokes + [growing], width: 2560, height: 1707, cache: cache))
        let clock = ContinuousClock()
        var slowest = Duration.zero
        for step in 1 ... 15 {
            growing.points.append(NormalizedPoint(x: 0.3 + Double(step) * 0.01, y: 0.5))
            let start = clock.now
            _ = try #require(BrushRasterizer.raster(strokes + [growing], width: 2560, height: 1707, cache: cache))
            slowest = max(slowest, start.duration(to: clock.now))
        }
        #expect(slowest < .milliseconds(100), "Slowest appended point: \(slowest)")
        print("Mask benchmark: slowest appended point=\(slowest)")
    }
}
