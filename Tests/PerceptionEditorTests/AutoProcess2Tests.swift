import CoreImage
import Foundation
import Testing
@testable import PerceptionEditor

/// Auto fits what the photo's own process will show. These mirror the process-1 tests in
/// `AutoAdjustmentTests` with process 2 photos, plus a scene-linear RAW-style case.
struct AutoProcess2Tests {
    private let space = CGColorSpace(name: CGColorSpace.sRGB)!

    /// A 64 × 64 horizontal gradient. `encoded` values are sRGB-encoded, as a decoded JPEG; scene
    /// values are linear, as a RAW decode.
    private func gradient(low: Double, high: Double, scene: Bool = false) -> CIImage {
        IQFixtures.image(width: 64, height: 64) { x, _ in
            let value = low + (high - low) * Double(x) / 63
            let linear = scene ? value : IQMetrics.srgbToLinear(value)
            return (Float(linear), Float(linear), Float(linear))
        }
    }

    private func photo(_ suggestion: AutoAdjustmentSuggestion) -> PhotoAdjustments {
        var base = PhotoAdjustments.neutral
        base.processVersion = 2
        return suggestion.applying(to: base)
    }

    /// Median and range of the sRGB-encoded luma the photo's process shows, and its brightest 1%.
    private func shown(_ image: CIImage, _ adjustments: PhotoAdjustments, raw: Bool) -> (median: Double, range: Double, white: Double) {
        let output = MediaColorRenderer.renderForAnalysis(image, adjustments: adjustments, isRAW: raw)
        let buffer = IQRender.pixels(of: output)
        let lumas = stride(from: 0, to: buffer.count, by: 4).map {
            0.2126 * Double(buffer[$0]) / 65535 + 0.7152 * Double(buffer[$0 + 1]) / 65535 + 0.0722 * Double(buffer[$0 + 2]) / 65535
        }.sorted()
        return (lumas[lumas.count / 2], lumas[lumas.count * 9 / 10] - lumas[lumas.count / 10], lumas[lumas.count * 99 / 100])
    }

    @Test func darkAndBrightScenesReceiveOppositeExposureAndMoveTowardMiddle() throws {
        let analyzer = AutoAdjustmentAnalyzer()
        let dark = gradient(low: 0.03, high: 0.32), bright = gradient(low: 0.65, high: 0.99)
        let a = try analyzer.suggest(for: dark, process: 2), b = try analyzer.suggest(for: bright, process: 2)
        #expect(a.basic.exposure > 0 && b.basic.exposure < 0)
        var neutral = PhotoAdjustments.neutral
        neutral.processVersion = 2
        let beforeDark = shown(dark, neutral, raw: false).median, afterDark = shown(dark, photo(a), raw: false).median
        let beforeBright = shown(bright, neutral, raw: false).median, afterBright = shown(bright, photo(b), raw: false).median
        #expect(afterDark > beforeDark + 0.06, "dark \(beforeDark) → \(afterDark)")
        #expect(afterBright < beforeBright - 0.06, "bright \(beforeBright) → \(afterBright)")
    }

    @Test func flatSceneGainsRangeAndBacklightingDoesNotBlowOutWhites() throws {
        let analyzer = AutoAdjustmentAnalyzer()
        var neutral = PhotoAdjustments.neutral
        neutral.processVersion = 2
        let flat = gradient(low: 0.39, high: 0.55)
        let flatEdit = try analyzer.suggest(for: flat, process: 2)
        #expect(shown(flat, photo(flatEdit), raw: false).range > shown(flat, neutral, raw: false).range + 0.015)

        let dark = gradient(low: 0.02, high: 0.30)
        let white = IQFixtures.image(width: 16, height: 64) { _, _ in
            let v = Float(IQMetrics.srgbToLinear(0.98)); return (v, v, v)
        }.transformed(by: CGAffineTransform(translationX: 48, y: 0))
        let backlit = white.composited(over: dark).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let edit = try analyzer.suggest(for: backlit, process: 2)
        let before = shown(backlit, neutral, raw: false), after = shown(backlit, photo(edit), raw: false)
        #expect(after.median > before.median + 0.04)
        #expect(after.white <= 1.0001)
    }

    @Test func aDarkSceneLinearRawFrameLandsNearMiddleGrey() throws {
        let analyzer = AutoAdjustmentAnalyzer()
        var neutral = PhotoAdjustments.neutral
        neutral.processVersion = 2
        // Real S5 frames decode with a linear median of 0.08–0.14; the last case is a bright, contrasty one.
        for (low, high) in [(0.002, 0.10), (0.004, 0.30), (0.01, 0.55)] {
            let frame = gradient(low: low, high: high, scene: true)
            let edit = try analyzer.suggest(for: frame, process: 2, isRAW: true)
            let before = shown(frame, neutral, raw: true).median, after = shown(frame, photo(edit), raw: true).median
            #expect(after > 0.3 && after < 0.7, "scene \(low)…\(high): median \(before) → \(after)")
            #expect(abs(after - 0.48) <= abs(before - 0.48) + 0.02, "never further from the target")
        }
    }

    @Test func autoRecoversBlownHighlightsOfABacklitRawFrame() throws {
        // A dark room with a bright window: the right quarter is scene-linear 2.0, where a sensor clips (above display white after the RAW default). The tone
        // equalizer smooths its mask, so a window has to be a region, not a few pixels, to be recovered.
        let frame = IQFixtures.image(width: 64, height: 64) { x, _ in
            let v = Float(x >= 48 ? 2.0 : 0.02 + 0.1 * Double(x) / 47)
            return (v, v, v)
        }
        var neutral = PhotoAdjustments.neutral
        neutral.processVersion = 2
        func clippedShare(_ adjustments: PhotoAdjustments) -> Double {
            let buffer = IQRender.pixels(of: MediaColorRenderer.renderForAnalysis(frame, adjustments: adjustments, isRAW: true))
            let lumas = stride(from: 0, to: buffer.count, by: 4).map {
                0.2126 * Double(buffer[$0]) / 65535 + 0.7152 * Double(buffer[$0 + 1]) / 65535 + 0.0722 * Double(buffer[$0 + 2]) / 65535
            }
            return Double(lumas.filter { $0 > 0.985 }.count) / Double(lumas.count)
        }
        let edit = try AutoAdjustmentAnalyzer().suggest(for: frame, process: 2, isRAW: true)
        let before = clippedShare(neutral), after = clippedShare(photo(edit))
        #expect(before > 0.2, "the window is blown to start with: \(before)")
        #expect(after < before / 2, "Auto brings it back: \(before) → \(after)")
        #expect(edit.basic.highlights < 0, "by recovering highlights")
    }

    @Test func repeatedAutoIsIdenticalInProcess2() throws {
        let analyzer = AutoAdjustmentAnalyzer()
        let frame = gradient(low: 0.03, high: 0.5, scene: true)
        let first = try analyzer.suggest(for: frame, process: 2, isRAW: true)
        let second = try analyzer.suggest(for: frame, process: 2, isRAW: true)
        #expect(first == second)
    }

    @Test func process1StaysExactlyWhatItWas() throws {
        let analyzer = AutoAdjustmentAnalyzer()
        let dark = gradient(low: 0.03, high: 0.32)
        let viaDefault = try analyzer.suggest(for: dark)
        let viaExplicit = try analyzer.suggest(for: dark, process: 1, isRAW: false)
        #expect(viaDefault == viaExplicit)
        #expect(viaDefault.basic.exposure > 0)
    }
}
