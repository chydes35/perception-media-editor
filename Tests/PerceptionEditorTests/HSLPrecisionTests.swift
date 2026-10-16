import CoreImage
import Foundation
import Metal
import simd
import Testing
@testable import PerceptionEditor

/// HSL at 10-bit precision, through the same Core Image graph photos and video use, on the GPU in
/// half float. The reference is `ColorGrading.applyHSL` in Double.
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct HSLPrecisionTests {
    static let space = CGColorSpace(name: CGColorSpace.extendedSRGB)!
    static let context = CIContext(mtlDevice: MTLCreateSystemDefaultDevice()!, options: [
        .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false
    ])

    /// Sends one row of sRGB-encoded colors through `MediaColorRenderer` and reads the result back
    /// as sRGB-encoded floats. Without other adjustments, the output is HSL applied to the input.
    static func render(_ colors: [SIMD3<Float>], _ adjustments: PhotoAdjustments) -> [SIMD3<Float>] {
        let width = colors.count
        var input = [Float](repeating: 1, count: width * 4)
        for (i, c) in colors.enumerated() { input[i * 4] = c.x; input[i * 4 + 1] = c.y; input[i * 4 + 2] = c.z }
        let data = input.withUnsafeBufferPointer { Data(buffer: $0) }
        let image = CIImage(bitmapData: data, bytesPerRow: width * 16, size: CGSize(width: width, height: 1),
                            format: .RGBAf, colorSpace: space)
        let output = MediaColorRenderer.render(image, adjustments: adjustments, includesGeometry: false)
        var result = [Float](repeating: 0, count: width * 4)
        context.render(output, toBitmap: &result, rowBytes: width * 16, bounds: CGRect(x: 0, y: 0, width: width, height: 1),
                       format: .RGBAf, colorSpace: space)
        return (0 ..< width).map { SIMD3(result[$0 * 4], result[$0 * 4 + 1], result[$0 * 4 + 2]) }
    }

    static func reference(_ hsl: HSLAdjustments, _ c: SIMD3<Float>) -> SIMD3<Float> {
        let r = ColorGrading.applyHSL(hsl, r: Double(c.x), g: Double(c.y), b: Double(c.z))
        return SIMD3(Float(r.r), Float(r.g), Float(r.b))
    }

    /// A clear sky: hue 200…230°, saturation 0.55, lightness rising 0.45…0.65 across 4000 pixels.
    static func sky(width: Int = 4000) -> [SIMD3<Float>] {
        (0 ..< width).map { x in
            let t = Double(x) / Double(width - 1)
            let c = ColorGrading.hslToRGB(200 + 30 * t, 0.55, 0.45 + 0.2 * t)
            return SIMD3(Float(c.r), Float(c.g), Float(c.b))
        }
    }

    static var skyGrade: HSLAdjustments {
        var hsl = HSLAdjustments()
        hsl.blue = HSLBandAdjustment(hue: 0, saturation: 0.6, luminance: -0.4)
        hsl.aqua = HSLBandAdjustment(hue: 0.2, saturation: 0.3, luminance: -0.2)
        return hsl
    }

    /// Worst distance from the exact curve, and the worst "kink": how much the output's second
    /// difference departs from the exact curve's. A cube's cell edges show up as kinks, which the eye
    /// sees as bands in a smooth sky even when every value is close.
    static func measure(_ output: [SIMD3<Float>], _ expected: [SIMD3<Float>]) -> (error: Float, kink: Float) {
        var error: Float = 0, kink: Float = 0
        for i in output.indices {
            error = max(error, simd_abs(output[i] - expected[i]).max())
            if i >= 1, i + 1 < output.count {
                let outCurvature = output[i + 1] - 2 * output[i] + output[i - 1]
                let refCurvature = expected[i + 1] - 2 * expected[i] + expected[i - 1]
                kink = max(kink, simd_abs(outCurvature - refCurvature).max())
            }
        }
        return (error, kink)
    }

    @Test func aGradedSkyFollowsTheExactHSLCurve() {
        var adjustments = PhotoAdjustments()
        adjustments.hsl = Self.skyGrade
        let input = Self.sky()
        let output = Self.render(input, adjustments)
        let expected = input.map { Self.reference(Self.skyGrade, $0) }
        let (error, kink) = Self.measure(output, expected)
        print("Sky: worst error \(error * 1023) of 1023, worst kink \(kink * 1023) of 1023")
        // The 48³ cube measured 4.1 here. Kinks are reported only: half-float rounding alone makes
        // second differences of up to a level, as large as the cube's.
        #expect(error <= 1.0 / 1023, "Sky departs from the exact HSL curve by \(error * 1023) of 1023 levels")
    }

    @Test func randomColorsMatchTheReference() {
        var hsl = HSLAdjustments()
        hsl.orange = HSLBandAdjustment(hue: -0.4, saturation: 0.5, luminance: 0.2)
        hsl.green = HSLBandAdjustment(hue: 0.6, saturation: -0.5, luminance: -0.2)
        hsl.blue = HSLBandAdjustment(hue: 0.3, saturation: 0.8, luminance: 0.3)
        hsl.magenta = HSLBandAdjustment(hue: -1, saturation: 1, luminance: -1)
        var adjustments = PhotoAdjustments()
        adjustments.hsl = hsl
        var generator = SeededGenerator(seed: 23)
        let input = (0 ..< 16_384).map { _ in
            SIMD3(Float.random(in: 0 ... 1, using: &generator), Float.random(in: 0 ... 1, using: &generator), Float.random(in: 0 ... 1, using: &generator))
        }
        let output = Self.render(input, adjustments)
        let errors = zip(output, input).map { simd_abs($0 - Self.reference(hsl, $1)).max() }
        let worst = errors.max() ?? 0, mean = errors.reduce(0, +) / Float(errors.count)
        print("Random colors: worst \(worst * 1023), mean \(mean * 1023) of 1023")
        #expect(worst <= 1.0 / 1023 && mean <= 0.25 / 1023, "Worst \(worst * 1023), mean \(mean * 1023) of 1023 levels")
    }

    @Test func aGreyRampWithEveryBandSaturatedStaysSmooth() {
        var hsl = HSLAdjustments()
        for band in HSLBand.allCases { hsl[band] = HSLBandAdjustment(hue: 0, saturation: 1, luminance: 0) }
        var adjustments = PhotoAdjustments()
        adjustments.hsl = hsl
        let input = (0 ..< 1024).map { SIMD3<Float>(repeating: Float($0) / 1023) }
        let output = Self.render(input, adjustments)
        var worstStep: Float = 0, monotonic = true
        for i in 1 ..< output.count {
            let step = output[i] - output[i - 1]
            if step.min() < -1e-5 { monotonic = false }
            worstStep = max(worstStep, step.max())
        }
        #expect(monotonic, "A grey ramp must keep rising")
        #expect(worstStep <= 2.0 / 1023, "Largest step \(worstStep * 1023) of 1023")
    }

    @Test func curvesAreSampledFinelyEnoughForTenBits() throws {
        // A strong S curve through Core Image's curve filter, against the curve itself.
        var curves = ToneCurves()
        curves.rgb = ToneCurve(points: [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.3, y: 0.12), CurvePoint(x: 0.7, y: 0.9), CurvePoint(x: 1, y: 1)])
        var adjustments = PhotoAdjustments()
        adjustments.curves = curves
        let input = (0 ..< 1024).map { SIMD3<Float>(repeating: Float($0) / 1023) }
        let output = Self.render(input, adjustments)
        let curve = try #require(curves.rgb)
        let worst = zip(output, input).map { abs($0.x - Float(curve.evaluate(Double($1.x)))) }.max() ?? 0
        print("Curve: worst \(worst * 1023) of 1023")
        #expect(worst <= 1.0 / 1023, "Curve departs from its points' curve by \(worst * 1023) of 1023 levels")
    }

    /// The interpolated cube is only the fallback for when the kernel cannot be compiled. Measured on
    /// solid-color images.
    @Test func theCubeFallbackStaysNearTheExactCurve() throws {
        let srgb = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var hsl = HSLAdjustments()
        hsl.orange = HSLBandAdjustment(hue: -0.4, saturation: 0.5, luminance: 0.2)
        hsl.blue = HSLBandAdjustment(hue: 0.3, saturation: 0.8, luminance: 0.3)
        var generator = SeededGenerator(seed: 29)
        let colors = (0 ..< 150).map { _ in
            SIMD3(Float.random(in: 0 ... 1, using: &generator), Float.random(in: 0 ... 1, using: &generator), Float.random(in: 0 ... 1, using: &generator))
        }
        func worst(_ method: HSLMethod) -> Float {
            colors.map { color in
                let solid = CIImage(color: CIColor(red: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z), colorSpace: srgb)!)
                    .cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
                var result = [Float](repeating: 0, count: 4)
                Self.context.render(MediaColorRenderer.applyHSL(hsl, to: solid, method: method), toBitmap: &result, rowBytes: 16,
                                    bounds: CGRect(x: 1, y: 1, width: 1, height: 1), format: .RGBAf, colorSpace: srgb)
                return simd_abs(SIMD3(result[0], result[1], result[2]) - Self.reference(hsl, color)).max()
            }.max() ?? .infinity
        }
        let cube = worst(.cube), kernel = worst(.kernel)
        print("Solid colors: cube (\(ColorGrading.cubeDimension)³) worst \(cube * 1023), kernel worst \(kernel * 1023) of 1023")
        // Measured 4.5 at 48³ (and 8.8 at 64³, which is why the fallback stays at 48).
        #expect(cube <= 6.0 / 1023, "The fallback cube departs by \(cube * 1023) of 1023 levels")
        #expect(kernel <= 1.0 / 1023)
        #expect(HSLColorKernel.isAvailable, "The exact kernel compiles on this Mac")
    }
}
