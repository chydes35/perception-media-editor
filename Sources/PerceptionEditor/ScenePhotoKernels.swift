import CoreImage
import Foundation

/// Core Image color kernels for process version 2, the scene-referred photo pipeline. Kernel-language
/// source compiles at run time like the HSL and LUT kernels, so Command Line Tools builds work.
///
/// Scene stages see linear Rec. 2020; the display stage turns that into display-referred linear sRGB,
/// which the color-grading stages (sat/vibrance, curves, HSL, grading, LUT) take over.
enum ScenePhotoKernels {
    static let lumaRec2020 = (r: 0.2627, g: 0.6780, b: 0.0593)

    /// Tone-equalizer band centers in EV relative to white (0 EV is a linear value of 1.0).
    static let bandCenters: [Double] = [-8, -7, -6, -5, -4, -3, -2, -1, 0]

    private final class Compiled: @unchecked Sendable {
        let logLuma = CIColorKernel(source: ScenePhotoKernels.logLumaSource)
        let tone = CIColorKernel(source: ScenePhotoKernels.toneSource)
        let display = CIColorKernel(source: ScenePhotoKernels.displaySource)
        let saturation = CIColorKernel(source: ScenePhotoKernels.saturationSource)
    }
    private static let compiled = Compiled()

    static var isAvailable: Bool {
        compiled.logLuma != nil && compiled.tone != nil && compiled.display != nil && compiled.saturation != nil
    }

    // MARK: - Wrappers

    /// log2 of the luminance in all three channels. Smoothing it gives the tone equalizer its mask.
    static func logLuma(_ image: CIImage) -> CIImage? {
        compiled.logLuma?.apply(extent: image.extent, arguments: [image])
    }

    /// Exposure gain, 9 tone-equalizer band gains (EV), and a power contrast about `pivot`.
    /// `mask` holds the smoothed log-luminance of the image before `gain` was applied.
    static func tone(_ image: CIImage, mask: CIImage, gain: Double, bands: [Double], contrast: Double, pivot: Double) -> CIImage? {
        precondition(bands.count == bandCenters.count)
        let arguments: [Any] = [image, mask] + bands.map { Float($0) } + [Float(gain), Float(contrast), Float(pivot)]
        return compiled.tone?.apply(extent: image.extent, arguments: arguments)
    }

    /// Sigmoid on luminance with colors scaled by the same ratio, then Rec. 2020 to sRGB with gamut
    /// compression toward the luminance. Output is display-referred linear sRGB in 0…1.
    static func display(_ image: CIImage, curve: SceneDisplayCurve) -> CIImage? {
        compiled.display?.apply(extent: image.extent, arguments: [
            image, Float(curve.contrast), Float(curve.scale), Float(curve.knee),
        ])
    }

    /// Saturation and vibrance in OkLCh on display-referred linear sRGB. `saturation` is a chroma
    /// multiplier (1 = unchanged); `vibrance` is −1…1 and favors muted colors and spares skin hues.
    static func saturation(_ image: CIImage, saturation: Double, vibrance: Double) -> CIImage? {
        compiled.saturation?.apply(extent: image.extent, arguments: [image, Float(saturation), Float(vibrance)])
    }

    // MARK: - Source

    private static let gamutCompression = """
    vec3 compressGamut(vec3 o) {
        float y = dot(o, vec3(0.2126, 0.7152, 0.0722));
        float mx = max(o.r, max(o.g, o.b));
        if (mx > 1.0 && y < 1.0) { o = y + (o - y) * ((1.0 - y) / (mx - y)); }
        float mn = min(o.r, min(o.g, o.b));
        if (mn < 0.0 && y > 0.0) { o = y + (o - y) * (y / (y - mn)); }
        return clamp(o, 0.0, 1.0);
    }
    """

    private static let logLumaSource = """
    kernel vec4 sceneLogLuma(__sample s) {
        float y = dot(s.rgb, vec3(\(lumaRec2020.r), \(lumaRec2020.g), \(lumaRec2020.b)));
        float l = log2(max(y, 0.000001));
        return vec4(l, l, l, 1.0);
    }
    """

    private static let toneSource: String = {
        let parameters = (0 ..< bandCenters.count).map { "float g\($0)" }.joined(separator: ", ")
        // Gaussian radial basis functions, one per band, sigma 0.8 EV (2σ² = 1.28). All gains zero
        // gives exactly zero, so an untouched equalizer is the identity.
        let blend = bandCenters.enumerated().map { index, center in
            "w = exp(-(ev - (\(center))) * (ev - (\(center))) / 1.28); wsum += w; gsum += w * g\(index);"
        }.joined(separator: "\n    ")
        return """
        kernel vec4 sceneTone(__sample s, __sample m, \(parameters), float gain, float cexp, float pivot) {
            vec3 c = s.rgb * gain;
            float ev = clamp(m.r + log2(gain), -8.0, 0.0);
            float w = 0.0; float wsum = 0.0; float gsum = 0.0;
            \(blend)
            c *= exp2(gsum / wsum);
            float y = dot(c, vec3(\(lumaRec2020.r), \(lumaRec2020.g), \(lumaRec2020.b)));
            if (cexp != 1.0 && y > 0.000001) { c *= clamp(pow(y / pivot, cexp - 1.0), 0.05, 20.0); }
            return vec4(c, s.a);
        }
        """
    }()

    private static let displaySource = """
    \(gamutCompression)
    kernel vec4 sceneDisplay(__sample s, float n, float scale, float knee) {
        vec3 c = s.rgb;
        float y = dot(c, vec3(\(lumaRec2020.r), \(lumaRec2020.g), \(lumaRec2020.b)));
        if (y <= 0.000001) { return vec4(0.0, 0.0, 0.0, s.a); }
        float yn = pow(y, n);
        float yd = scale * yn / (yn + knee);
        c *= yd / y;
        vec3 o = vec3(dot(c, vec3(1.660491, -0.587641, -0.072850)),
                      dot(c, vec3(-0.124550, 1.132900, -0.008349)),
                      dot(c, vec3(-0.018151, -0.100579, 1.118730)));
        return vec4(compressGamut(o), s.a);
    }
    """

    private static let saturationSource: String = {
        // Bisection on the chroma scale at constant OkLab hue: the largest scale whose color fits in
        // sRGB. Eight steps leave an error under half a percent of chroma, far below one code value.
        let steps = (0 ..< 8).map { _ in
            """
                mid = 0.5 * (lo + hi);
                if (fitsGamut(oklabToLinear(L, a * mid, b * mid)) > 0.5) { lo = mid; } else { hi = mid; }
            """
        }.joined(separator: "\n")
        return """
        vec3 oklabToLinear(float L, float a, float b) {
            float l2 = L + 0.3963377774 * a + 0.2158037573 * b;
            float m2 = L - 0.1055613458 * a - 0.0638541728 * b;
            float s2 = L - 0.0894841775 * a - 1.2914855480 * b;
            l2 = l2 * l2 * l2; m2 = m2 * m2 * m2; s2 = s2 * s2 * s2;
            return vec3(4.0767416621 * l2 - 3.3077115913 * m2 + 0.2309699292 * s2,
                        -1.2684380046 * l2 + 2.6097574011 * m2 - 0.3413193965 * s2,
                        -0.0041960863 * l2 - 0.7034186147 * m2 + 1.7076147010 * s2);
        }
        float fitsGamut(vec3 o) {
            float low = min(o.r, min(o.g, o.b));
            float high = max(o.r, max(o.g, o.b));
            return (low >= -0.0005 && high <= 1.0005) ? 1.0 : 0.0;
        }
        kernel vec4 sceneSaturation(__sample s, float sat, float vib) {
            vec3 c = max(s.rgb, vec3(0.0));
            float l_ = pow(0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b, 0.333333333);
            float m_ = pow(0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b, 0.333333333);
            float s_ = pow(0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b, 0.333333333);
            float L = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_;
            float a = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_;
            float b = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_;
            float chroma = sqrt(a * a + b * b);
            float hue = atan(b, a);
            float muted = 1.0 - clamp(chroma / 0.30, 0.0, 1.0);
            float skin = 1.0 - 0.6 * exp(-(hue - 0.75) * (hue - 0.75) / 0.12);
            float factor = max(0.0, sat * (1.0 + vib * muted * skin));
            a *= factor; b *= factor;
            vec3 o = oklabToLinear(L, a, b);
            if (fitsGamut(o) < 0.5) {
                float lo = 0.0; float hi = 1.0; float mid = 0.5;
        \(steps)
                o = oklabToLinear(L, a * lo, b * lo);
            }
            return vec4(clamp(o, 0.0, 1.0), s.a);
        }
        """
    }()
}

/// The display transform's shape. A sigmoid on luminance, `scale·yⁿ / (yⁿ + knee)`, solved so scene
/// middle grey lands on display middle grey and the scene white point lands exactly on display white.
struct SceneDisplayCurve: Equatable, Sendable {
    var contrast: Double
    var scale: Double
    var knee: Double

    static let middleGrey = 0.18

    /// - Parameters:
    ///   - contrast: the exponent n; it must be above 1 (1 would be a straight line).
    ///   - whitePoint: the scene value that maps to display white.
    init(contrast: Double, whitePoint: Double) {
        let n = max(1.001, contrast)
        let a = pow(Self.middleGrey, n), w = pow(max(whitePoint, 0.5), n)
        let denominator = Self.middleGrey * w - a
        let knee = a * w * (1 - Self.middleGrey) / max(denominator, 1e-9)
        self.contrast = n
        self.knee = knee
        self.scale = Self.middleGrey * (a + knee) / a
    }

    /// The transform on one luminance value, for tests and for reasoning about the curve.
    func map(_ y: Double) -> Double {
        guard y > 0 else { return 0 }
        let yn = pow(y, contrast)
        return scale * yn / (yn + knee)
    }

    /// Exposure, in EV, applied to every RAW decode before the Exposure slider. With the engine's own
    /// boost curve off, S5 frames decode about one stop darker than the same frames did with it (median
    /// luminance 0.08–0.14 against 0.14–0.29 on six real frames), so this puts them back where
    /// middle grey sits. The slider stays at 0 for an untouched photo.
    static let rawExposureOffset = 1.0

    /// RAW decodes carry two stops of headroom above 1.0; display-referred files end at 1.0 and
    /// already have their own tone curve, so theirs is nearly straight.
    static let raw = SceneDisplayCurve(contrast: 1.45, whitePoint: 4.0)
    static let displayReferred = SceneDisplayCurve(contrast: 1.1, whitePoint: 1.0)
}
