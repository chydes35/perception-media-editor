import CoreImage
import Foundation
import Testing
@testable import PerceptionEditor

struct ToneCurveTests {
    @Test func aStraightCurveChangesNothing() {
        let curve = ToneCurve.linear
        #expect(curve.isLinear)
        for x in stride(from: 0.0, through: 1.0, by: 0.1) {
            #expect(abs(curve.evaluate(x) - x) < 1e-9)
        }
        let table = curve.lookupTable()
        #expect(table.count == 256)
        #expect(abs(Double(table[128]) - 128.0 / 255.0) < 1e-6)
    }

    @Test func theCurvePassesExactlyThroughItsPoints() {
        let curve = ToneCurve(points: [
            CurvePoint(x: 0, y: 0.05), CurvePoint(x: 0.3, y: 0.2), CurvePoint(x: 0.7, y: 0.85), CurvePoint(x: 1, y: 1)
        ])
        for point in curve.points {
            #expect(abs(curve.evaluate(point.x) - point.y) < 1e-9)
        }
    }

    @Test func aRisingCurveNeverOvershootsOrDips() {
        // A steep jump followed by a plateau is where ordinary splines overshoot.
        let curve = ToneCurve(points: [
            CurvePoint(x: 0, y: 0), CurvePoint(x: 0.4, y: 0.9), CurvePoint(x: 0.6, y: 0.92), CurvePoint(x: 1, y: 1)
        ])
        var previous = 0.0
        for i in 0 ... 1000 {
            let value = curve.evaluate(Double(i) / 1000)
            #expect(value >= previous - 1e-9)
            #expect(value >= 0 && value <= 1)
            previous = value
        }
    }

    @Test func presetsAreValidAndContrastPresetsAreSShaped() throws {
        for (name, curve) in ToneCurve.presets {
            #expect(curve.points.first?.x == 0 && curve.points.last?.x == 1, "\(name) must span 0…1")
            let xs = curve.points.map(\.x)
            #expect(xs == xs.sorted(), "\(name) points must be sorted")
        }
        let medium = try #require(ToneCurve.presets.first { $0.name == "Medium Contrast" }?.curve)
        #expect(medium.evaluate(0.25) < 0.25)
        #expect(medium.evaluate(0.75) > 0.75)
        #expect(abs(medium.evaluate(0.5) - 0.5) < 0.02)
    }

    @Test func movingPointsKeepsThemOrderedAndEndsFixedHorizontally() {
        var curve = ToneCurve(points: [
            CurvePoint(x: 0, y: 0), CurvePoint(x: 0.3, y: 0.3), CurvePoint(x: 0.6, y: 0.6), CurvePoint(x: 1, y: 1)
        ])

        curve.movePoint(at: 1, to: CGPoint(x: 0.9, y: 0.4))
        #expect(curve.points[1].x < 0.6)
        #expect(curve.points[1].x >= 0.6 - ToneCurve.minimumGap - 1e-9)

        curve.movePoint(at: 2, to: CGPoint(x: -1, y: 2))
        #expect(curve.points[2].y == 1)
        #expect(curve.points[2].x > curve.points[1].x)

        curve.movePoint(at: 0, to: CGPoint(x: 0.5, y: 0.2))
        #expect(curve.points[0].x == 0 && curve.points[0].y == 0.2)
        curve.movePoint(at: 3, to: CGPoint(x: 0.1, y: 0.7))
        #expect(curve.points[3].x == 1 && curve.points[3].y == 0.7)
    }

    @Test func pointsCanBeAddedAndRemovedWithinLimits() throws {
        var curve = ToneCurve.linear
        let added = curve.addPoint(x: 0.5, y: 0.4)
        let index = try #require(added)
        #expect(index == 1 && curve.points.count == 3)

        #expect(curve.addPoint(x: 0.505, y: 0.9) == nil, "too close to an existing point")
        #expect(curve.points.count == 3)

        curve.removePoint(at: 0)
        curve.removePoint(at: 2)
        #expect(curve.points.count == 3, "the end points stay")
        curve.removePoint(at: 1)
        #expect(curve.isLinear)

        var full = ToneCurve.linear
        for i in 1 ..< ToneCurve.maximumPoints - 1 { full.addPoint(x: Double(i) / Double(ToneCurve.maximumPoints), y: 0.5) }
        #expect(full.points.count == ToneCurve.maximumPoints)
        #expect(full.addPoint(x: 0.999, y: 0.5) == nil)
    }

    @Test func theNearestPointIsFoundWithinTheGrabRadius() {
        let curve = ToneCurve(points: [
            CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.5), CurvePoint(x: 1, y: 1)
        ])
        #expect(curve.nearestPoint(to: CGPoint(x: 0.52, y: 0.48), radius: 0.05) == 1)
        #expect(curve.nearestPoint(to: CGPoint(x: 0.7, y: 0.3), radius: 0.05) == nil)
        #expect(curve.nearestPoint(to: CGPoint(x: 0.02, y: 0.01), radius: 0.05) == 0)
    }

    @Test func curvesRoundTripAndStraightChannelsStoreNothing() throws {
        var curves = ToneCurves()
        curves[.red] = ToneCurve(points: [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.6), CurvePoint(x: 1, y: 1)])
        curves[.blue] = .linear
        #expect(curves.blue == nil)
        #expect(curves.rgb == nil && curves.red != nil)
        #expect(!curves.isNeutral)

        let decoded = try JSONDecoder().decode(ToneCurves.self, from: JSONEncoder().encode(curves))
        #expect(decoded == curves)
        #expect(ToneCurves().isNeutral)
        #expect(try JSONEncoder().encode(ToneCurves()) == Data("{}".utf8))
    }

    @Test func curveDataIsSkippedWhenStraightAndComposesChannelsAfterTheMaster() throws {
        #expect(ColorGrading.curveData(ToneCurves()) == nil)

        var curves = ToneCurves()
        curves[.rgb] = ToneCurve(points: [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.25), CurvePoint(x: 1, y: 1)])
        let data = try #require(ColorGrading.curveData(curves, samples: 256))
        let values = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        #expect(values.count == 256 * 3)
        // Input 0.5 → 0.25 on all three channels.
        let mid = 128 * 3
        #expect(abs(values[mid] - 0.25) < 0.01 && abs(values[mid + 1] - 0.25) < 0.01 && abs(values[mid + 2] - 0.25) < 0.01)

        curves[.red] = ToneCurve(points: [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.25, y: 0.5), CurvePoint(x: 1, y: 1)])
        let composed = try #require(ColorGrading.curveData(curves, samples: 256))
        let v2 = composed.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        #expect(v2[mid] > 0.45, "red goes through the master first (0.5 → 0.25) then its own curve (0.25 → 0.5)")
        #expect(abs(v2[mid + 1] - 0.25) < 0.01)
    }
}

struct HSLTests {
    @Test func neutralAdjustmentsChangeNothing() {
        let hsl = HSLAdjustments()
        #expect(hsl.isNeutral)
        for (r, g, b) in [(0.9, 0.2, 0.1), (0.1, 0.8, 0.3), (0.3, 0.3, 0.9), (0.5, 0.5, 0.5), (1.0, 1.0, 0.0)] {
            let out = ColorGrading.applyHSL(hsl, r: r, g: g, b: b)
            #expect(abs(out.r - r) < 1e-6 && abs(out.g - g) < 1e-6 && abs(out.b - b) < 1e-6)
        }
    }

    @Test func colorConversionRoundTrips() {
        var generator = SeededGenerator(seed: 7)
        for _ in 0 ..< 500 {
            let r = Double.random(in: 0 ... 1, using: &generator)
            let g = Double.random(in: 0 ... 1, using: &generator)
            let b = Double.random(in: 0 ... 1, using: &generator)
            let hsl = ColorGrading.rgbToHSL(r, g, b)
            let back = ColorGrading.hslToRGB(hsl.h, hsl.s, hsl.l)
            #expect(abs(back.r - r) < 1e-9 && abs(back.g - g) < 1e-9 && abs(back.b - b) < 1e-9)
        }
    }

    @Test func eachBandOwnsItsCenterHueAndBlendsBetween() {
        var hsl = HSLAdjustments()
        hsl.green.saturation = 0.8
        hsl.blue.saturation = -0.4

        #expect(abs(hsl.adjustment(atHue: HSLBand.green.centerHue).saturation - 0.8) < 1e-9)
        #expect(abs(hsl.adjustment(atHue: HSLBand.blue.centerHue).saturation + 0.4) < 1e-9)
        // Between green (120°) and aqua (180°), the effect fades out smoothly.
        let midway = hsl.adjustment(atHue: 150).saturation
        #expect(midway > 0.2 && midway < 0.6)
        #expect(abs(hsl.adjustment(atHue: 180).saturation) < 1e-9)
        // Red wraps around 360°.
        hsl.red.hue = 1
        #expect(abs(hsl.adjustment(atHue: 0).hue - 1) < 1e-9)
        #expect(hsl.adjustment(atHue: 350).hue > 0 && hsl.adjustment(atHue: 350).hue < 1)
        #expect(abs(hsl.adjustment(atHue: 360).hue - 1) < 1e-9)
    }

    @Test func shiftingTheGreenHueRotatesGreensAndLeavesOtherColorsAlone() {
        var hsl = HSLAdjustments()
        hsl.green.hue = 1

        let green = ColorGrading.applyHSL(hsl, r: 0.1, g: 0.8, b: 0.1)
        let before = ColorGrading.rgbToHSL(0.1, 0.8, 0.1).h
        let after = ColorGrading.rgbToHSL(green.r, green.g, green.b).h
        #expect(abs((after - before) - 30) < 1.0, "+1 hue is +30°")

        let blue = ColorGrading.applyHSL(hsl, r: 0.1, g: 0.1, b: 0.9)
        #expect(abs(blue.r - 0.1) < 1e-6 && abs(blue.g - 0.1) < 1e-6 && abs(blue.b - 0.9) < 1e-6)
    }

    @Test func saturationAndLuminanceActOnTheirBandOnly() {
        var hsl = HSLAdjustments()
        hsl.orange.saturation = -1
        let orange = ColorGrading.applyHSL(hsl, r: 0.9, g: 0.5, b: 0.1)
        #expect(abs(orange.r - orange.g) < 0.05 && abs(orange.g - orange.b) < 0.05, "fully desaturated")

        var brighter = HSLAdjustments()
        brighter.red.luminance = 1
        let red = ColorGrading.applyHSL(brighter, r: 0.8, g: 0.1, b: 0.1)
        #expect(ColorGrading.rgbToHSL(red.r, red.g, red.b).l > ColorGrading.rgbToHSL(0.8, 0.1, 0.1).l + 0.2)

        let cyan = ColorGrading.applyHSL(brighter, r: 0.1, g: 0.8, b: 0.8)
        #expect(abs(cyan.r - 0.1) < 1e-6 && abs(cyan.g - 0.8) < 1e-6)
    }

    @Test func grayAndNearGrayAreNeverTinted() {
        var hsl = HSLAdjustments()
        for band in HSLBand.allCases { hsl[band] = HSLBandAdjustment(hue: 1, saturation: 1, luminance: 1) }

        let gray = ColorGrading.applyHSL(hsl, r: 0.4, g: 0.4, b: 0.4)
        #expect(gray.r == 0.4 && gray.g == 0.4 && gray.b == 0.4)

        // A very faint tint moves only a little, so skies and skin do not flicker at the edges.
        let faint = ColorGrading.applyHSL(hsl, r: 0.502, g: 0.5, b: 0.5)
        #expect(abs(faint.r - 0.502) < 0.01 && abs(faint.g - 0.5) < 0.01)
    }

    @Test func theCubeHasOneEntryPerNodeAndIsCached() {
        var hsl = HSLAdjustments()
        hsl.aqua.hue = -0.5
        let cube = ColorGrading.hslCube(hsl, dimension: 17)
        #expect(cube.count == 17 * 17 * 17 * 4 * MemoryLayout<Float>.size)
        #expect(ColorGrading.hslCube(hsl, dimension: 17) == cube)

        let values = cube.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        // Node (0, 0, 0) is black with alpha 1, and the last node is white.
        #expect(values[0] == 0 && values[3] == 1)
        #expect(values[values.count - 4] == 1 && values[values.count - 2] == 1)
    }

    @Test func hslSurvivesSaveAndOpenAndNeutralStoresNothing() throws {
        var adjustments = PhotoAdjustments()
        #expect(adjustments.hsl == nil)
        adjustments.hsl = HSLAdjustments(orange: HSLBandAdjustment(hue: 0.2, saturation: -0.3, luminance: 0.1))
        adjustments.curves[.rgb] = ToneCurve.presets[1].curve

        let decoded = try JSONDecoder().decode(PhotoAdjustments.self, from: JSONEncoder().encode(adjustments))
        #expect(decoded == adjustments)

        let plain = try JSONDecoder().decode(PhotoAdjustments.self, from: JSONEncoder().encode(PhotoAdjustments()))
        #expect(plain.hsl == nil && plain.curves.isNeutral)
    }
}

/// The real Core Image filters, checked against the math above.
struct GradingRenderTests {
    private let context = CIContext(options: [.useSoftwareRenderer: true])
    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Renders one sRGB color through the pipeline and returns the 8-bit sRGB result.
    private func render(_ color: (r: Double, g: Double, b: Double), _ adjustments: PhotoAdjustments) -> (r: Int, g: Int, b: Int) {
        let source = CIImage(color: CIColor(red: color.r, green: color.g, blue: color.b, colorSpace: srgb)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        let output = MediaColorRenderer.render(source, adjustments: adjustments, includesGeometry: false)
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 2, y: 2, width: 1, height: 1), format: .RGBA8, colorSpace: srgb)
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    @Test func aCurveMapsGrayLevelsAsDrawn() {
        var adjustments = PhotoAdjustments()
        adjustments.curves[.rgb] = ToneCurve(points: [
            CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.25), CurvePoint(x: 1, y: 1)
        ])

        let mid = render((0.5, 0.5, 0.5), adjustments)
        #expect(abs(mid.r - 64) <= 3 && abs(mid.g - 64) <= 3 && abs(mid.b - 64) <= 3)
        let white = render((1, 1, 1), adjustments)
        #expect(white.r >= 253)
        let black = render((0, 0, 0), adjustments)
        #expect(black.r <= 2)
    }

    @Test func aStraightCurveLeavesColorsExactlyAlone() {
        let untouched = render((0.3, 0.6, 0.9), PhotoAdjustments())
        var adjustments = PhotoAdjustments()
        adjustments.curves.rgb = .linear
        #expect(render((0.3, 0.6, 0.9), adjustments) == untouched)
    }

    @Test func aSingleChannelCurveOnlyChangesThatChannel() {
        var adjustments = PhotoAdjustments()
        adjustments.curves[.blue] = ToneCurve(points: [
            CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.7), CurvePoint(x: 1, y: 1)
        ])
        let base = render((0.5, 0.5, 0.5), PhotoAdjustments())
        let result = render((0.5, 0.5, 0.5), adjustments)
        #expect(result.b > base.b + 30)
        #expect(abs(result.r - base.r) <= 2 && abs(result.g - base.g) <= 2)
    }

    @Test func theHSLAppliedByCoreImageMatchesTheMath() {
        var hsl = HSLAdjustments()
        hsl.orange = HSLBandAdjustment(hue: -0.4, saturation: 0.5, luminance: 0.2)
        hsl.green = HSLBandAdjustment(hue: 0.6, saturation: -0.5, luminance: -0.2)
        hsl.blue = HSLBandAdjustment(hue: 0.3, saturation: 0.8, luminance: 0.3)
        var adjustments = PhotoAdjustments()
        adjustments.hsl = hsl

        var generator = SeededGenerator(seed: 11)
        var worst = 0
        for _ in 0 ..< 60 {
            let color = (
                r: Double.random(in: 0 ... 1, using: &generator),
                g: Double.random(in: 0 ... 1, using: &generator),
                b: Double.random(in: 0 ... 1, using: &generator)
            )
            let expected = ColorGrading.applyHSL(hsl, r: color.r, g: color.g, b: color.b)
            let actual = render(color, adjustments)
            let difference = max(
                abs(Double(actual.r) - expected.r * 255),
                abs(Double(actual.g) - expected.g * 255),
                abs(Double(actual.b) - expected.b * 255)
            )
            worst = max(worst, Int(difference.rounded()))
        }
        // The exact kernel (software renderer here); only 8-bit rounding is left.
        #expect(worst <= 1, "worst channel error was \(worst) levels")
    }

    @Test func aNeutralHSLLeavesTheImageUntouched() {
        var adjustments = PhotoAdjustments()
        adjustments.hsl = HSLAdjustments()
        #expect(render((0.9, 0.3, 0.2), adjustments) == render((0.9, 0.3, 0.2), PhotoAdjustments()))
    }

    @Test func desaturatingAColorBandTurnsThatColorGray() {
        var adjustments = PhotoAdjustments()
        var hsl = HSLAdjustments()
        hsl.red.saturation = -1
        adjustments.hsl = hsl

        let red = render((0.85, 0.15, 0.1), adjustments)
        #expect(abs(red.r - red.g) < 40 && abs(red.g - red.b) < 40)
        let blue = render((0.1, 0.2, 0.9), adjustments)
        let untouched = render((0.1, 0.2, 0.9), PhotoAdjustments())
        #expect(abs(blue.b - untouched.b) <= 3)
    }
}
