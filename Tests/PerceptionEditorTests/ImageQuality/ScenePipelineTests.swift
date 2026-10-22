import CoreImage
import Foundation
import Testing
@testable import PerceptionEditor

/// Process version 2 properties, measured on synthetic scenes (see `IQFixtures`).
struct ScenePipelineTests {
    @Test func theKernelsCompile() {
        #expect(ScenePhotoKernels.isAvailable)
    }

    @Test func displayCurveHitsItsAnchors() {
        for (curve, white) in [(SceneDisplayCurve.raw, 8.0), (SceneDisplayCurve.displayReferred, 1.0)] {
            #expect(abs(curve.map(0.18) - 0.18) < 1e-9, "middle grey stays put")
            #expect(abs(curve.map(white) - 1) < 1e-9, "the white point lands on display white")
            #expect(curve.map(0) == 0)
            var previous = 0.0
            for exponent in stride(from: -12.0, through: 3.0, by: 0.05) {
                let mapped = curve.map(pow(2, exponent))
                #expect(mapped >= previous, "monotonic")
                previous = mapped
            }
        }
    }

    @Test(arguments: [false, true])
    func aNeutralRampStaysNeutralAndMonotonic(raw: Bool) {
        let ramp = IQFixtures.grayRamp()
        let output = IQRender.photo(ramp, IQRender.version2(), raw: raw)
        var previous = -1.0
        for x in 0..<256 {
            let pixel = IQRender.linear(output, width: 256, x: x, y: 16)
            let spread = max(pixel.r, pixel.g, pixel.b) - min(pixel.r, pixel.g, pixel.b)
            #expect(spread < 0.004, "x=\(x) is tinted by \(spread)")
            let luma = IQRender.luma(pixel)
            #expect(luma >= previous - 1e-4, "monotonic at x=\(x)")
            previous = luma
        }
    }

    @Test func rawHighlightsRollOffInsteadOfClippingAtWhite() {
        let ramp = IQFixtures.highlightRamp()
        let output = IQRender.photo(ramp, IQRender.version2(), raw: true)
        // Scene value 1.0 sits at x = 51 and 4.0 at x = 153; 0.5 · 32^(x/255). RAW gets its default offset.
        let gain = pow(2, SceneDisplayCurve.rawExposureOffset)
        let atWhite = IQRender.luma(IQRender.linear(output, width: 256, x: 51, y: 16))
        let atTwoStopsOver = IQRender.luma(IQRender.linear(output, width: 256, x: 153, y: 16))
        #expect(abs(atWhite - SceneDisplayCurve.raw.map(1 * gain)) < 0.01)
        #expect(atWhite < 0.95, "a raw white is not pinned to display white")
        #expect(atTwoStopsOver > 0.98)
    }

    @Test func shadowsLiftTheDarksAndLeaveTheBrightsAlone() {
        let ramp = IQFixtures.grayRamp()
        let neutral = IQRender.photo(ramp, IQRender.version2(), raw: true)
        let lifted = IQRender.photo(ramp, IQRender.version2 { $0.shadows = 1 }, raw: true)
        // 2⁻⁶ at x = 73 (a dark tone); 2⁻⁰·⁵ at x = 173 (a bright one).
        let dark = IQRender.luma(IQRender.linear(lifted, width: 256, x: 73, y: 16))
            / IQRender.luma(IQRender.linear(neutral, width: 256, x: 73, y: 16))
        let bright = IQRender.luma(IQRender.linear(lifted, width: 256, x: 173, y: 16))
            / IQRender.luma(IQRender.linear(neutral, width: 256, x: 173, y: 16))
        #expect(dark > 1.5, "shadows +1 lifts a dark tone by \(dark)×")
        #expect(bright < 1.15, "and moves a bright tone by only \(bright)×")
    }

    @Test func highlightsRecoverTheBrightsAndLeaveTheDarksAlone() {
        let ramp = IQFixtures.grayRamp()
        let neutral = IQRender.photo(ramp, IQRender.version2(), raw: true)
        let recovered = IQRender.photo(ramp, IQRender.version2 { $0.highlights = -1 }, raw: true)
        let bright = IQRender.luma(IQRender.linear(recovered, width: 256, x: 173, y: 16))
            / IQRender.luma(IQRender.linear(neutral, width: 256, x: 173, y: 16))
        let dark = IQRender.luma(IQRender.linear(recovered, width: 256, x: 73, y: 16))
            / IQRender.luma(IQRender.linear(neutral, width: 256, x: 73, y: 16))
        #expect(bright < 0.75, "highlights −1 darkens a bright tone to \(bright)×")
        #expect(dark > 0.95, "and a dark tone only to \(dark)×")
    }

    @Test func exposureIsALinearGainBeforeTheDisplayTransform() {
        let flat = IQFixtures.image(width: 8, height: 8) { _, _ in (0.05, 0.05, 0.05) }
        let base = IQRender.luma(IQRender.linear(IQRender.photo(flat, IQRender.version2(), raw: true), width: 8, x: 4, y: 4))
        let plusOne = IQRender.luma(IQRender.linear(IQRender.photo(flat, IQRender.version2 { $0.exposure = 1 }, raw: true), width: 8, x: 4, y: 4))
        let gain = pow(2, SceneDisplayCurve.rawExposureOffset)
        let expected = SceneDisplayCurve.raw.map(0.1 * gain)
        #expect(abs(base - SceneDisplayCurve.raw.map(0.05 * gain)) < 0.003)
        #expect(abs(plusOne - expected) < 0.004, "+1 EV doubles the scene value: \(plusOne) vs \(expected)")
    }

    @Test func saturationKeepsTheHue() {
        let sweep = IQFixtures.gamutSweep()
        let before = IQRender.photo(sweep, IQRender.version2())
        let after = IQRender.photo(sweep, IQRender.version2 { $0.saturation = 0.5 })
        var checked = 0
        for y in 0..<64 {
            for x in stride(from: 0, to: 256, by: 4) {
                let a = IQRender.linear(before, width: 256, x: x, y: y)
                let b = IQRender.linear(after, width: 256, x: x, y: y)
                let lchA = IQMetrics.oklch(fromLinear: a.r, a.g, a.b)
                let lchB = IQMetrics.oklch(fromLinear: b.r, b.g, b.b)
                guard lchA.C > 0.05 else { continue }
                checked += 1
                #expect(lchB.C >= lchA.C - 0.005, "saturation never removes chroma")
                #expect(IQMetrics.hueDifference(lchA.h, lchB.h) < 1.0, "hue moved at (\(x),\(y))")
            }
        }
        #expect(checked > 100)
    }

    @Test func vibranceFavorsMutedColors() {
        let sweep = IQFixtures.gamutSweep()
        let before = IQRender.photo(sweep, IQRender.version2())
        let after = IQRender.photo(sweep, IQRender.version2 { $0.vibrance = 0.8 })
        func meanGain(rows: Range<Int>) -> Double {
            var gains: [Double] = []
            for y in rows {
                for x in stride(from: 0, to: 256, by: 4) {
                    let a = IQRender.linear(before, width: 256, x: x, y: y)
                    let b = IQRender.linear(after, width: 256, x: x, y: y)
                    let ca = IQMetrics.oklch(fromLinear: a.r, a.g, a.b).C
                    let cb = IQMetrics.oklch(fromLinear: b.r, b.g, b.b).C
                    if ca > 0.02 { gains.append(cb / ca) }
                }
            }
            return gains.reduce(0, +) / Double(max(1, gains.count))
        }
        // Rows 44…63 are the least saturated band, rows 0…21 the most.
        #expect(meanGain(rows: 44..<64) > meanGain(rows: 0..<22) + 0.05)
    }

    @Test func theVignetteSitsOnTheCroppedPicture() {
        let flat = IQFixtures.image(width: 256, height: 128) { _, _ in (0.4, 0.4, 0.4) }
        func corners(_ adjustments: PhotoAdjustments) -> (spread: Double, center: Double, corner: Double) {
            let output = IQRender.photo(flat, adjustments)
            let side = 128
            let tl = IQRender.luma(IQRender.linear(output, width: side, x: 2, y: 2))
            let tr = IQRender.luma(IQRender.linear(output, width: side, x: side - 3, y: 2))
            let bl = IQRender.luma(IQRender.linear(output, width: side, x: 2, y: side - 3))
            let br = IQRender.luma(IQRender.linear(output, width: side, x: side - 3, y: side - 3))
            let center = IQRender.luma(IQRender.linear(output, width: side, x: side / 2, y: side / 2))
            return (max(tl, tr, bl, br) - min(tl, tr, bl, br), center, (tl + tr + bl + br) / 4)
        }
        let rightHalf = CropRect(x: 0.5, y: 0, width: 0.5, height: 1)
        let two = corners(IQRender.version2 { $0.cropRect = rightHalf; $0.vignette = 0.8 })
        #expect(two.spread < 0.01, "the four corners darken equally: spread \(two.spread)")
        #expect(two.center - two.corner > 0.05, "and the center stays brighter")

        var legacy = PhotoAdjustments()
        legacy.processVersion = 1
        legacy.cropRect = rightHalf
        legacy.vignette = 0.8
        let one = corners(legacy)
        #expect(one.spread > two.spread * 3, "version 1 vignettes the uncropped frame, so the crop is lopsided")
    }

    @Test func aMaskedExposureStaysBelowDisplayWhite() {
        var mask = LocalMask(shape: .radial(center: NormalizedPoint(x: 0.5, y: 0.5), radiusX: 3, radiusY: 3, rotation: 0, feather: 0))
        mask.adjustments.exposure = 3
        let ramp = IQFixtures.highlightRamp()
        let output = IQRender.photo(ramp, IQRender.version2 { $0.masks = [mask] }, raw: true)
        var previous = -1.0
        for x in 0..<256 {
            let luma = IQRender.luma(IQRender.linear(output, width: 256, x: x, y: 16))
            #expect(luma <= 1.0001)
            #expect(luma >= previous - 1e-4, "monotonic at x=\(x)")
            previous = luma
        }
    }
}
