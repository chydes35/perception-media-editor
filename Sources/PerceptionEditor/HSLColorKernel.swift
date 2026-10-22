import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// The HSL adjustment as a Core Image color kernel: the exact math of `ColorGrading.applyHSL`, per
/// pixel, wherever Core Image runs (GPU or software). It replaced a 48³ color cube, whose trilinear
/// interpolation missed the exact result by up to 37 of 1023 levels near the hue wrap and the grey
/// threshold, and by 4 in a graded sky.
///
/// It is a color kernel rather than a processor kernel because it must sit inside Core Image's own
/// graph: the video compositor encodes its decode on the same command buffer just before grading,
/// and a processor kernel runs on Core Image's command buffer, which read the frame before the
/// decode had written it. Kernel-language source compiles at run time, like the healing kernel.
enum HSLColorKernel {
    /// Compiled once. A compiled kernel is immutable and safe on concurrent render queues.
    private final class Compiled: @unchecked Sendable {
        let kernel = CIColorKernel(source: HSLColorKernel.source)
    }
    private static let compiled = Compiled()

    static var isAvailable: Bool { compiled.kernel != nil }

    /// `image` holds sRGB-encoded color. Returns nil when the kernel is unavailable.
    static func apply(_ hsl: HSLAdjustments, to image: CIImage) -> CIImage? {
        guard let kernel = compiled.kernel else { return nil }
        let bands: [Any] = HSLBand.allCases.map { band in
            let adjustment = hsl[band]
            return CIVector(x: adjustment.hue, y: adjustment.saturation, z: adjustment.luminance)
        }
        return kernel.apply(extent: image.extent, arguments: [image] + bands)
    }

    /// Band centers 0, 30, 60, 120, 180, 240, 270 and 300 degrees, in `HSLBand` order; `b0`…`b7`
    /// carry each band's hue, saturation and luminance. The segment search is unrolled because the
    /// kernel language has no arrays.
    private static let source: String = {
        let centers: [Double] = HSLBand.allCases.map(\.centerHue)
        var segments = ""
        for index in 0 ..< centers.count {
            let next = (index + 1) % centers.count
            let low = centers[index], high = next == 0 ? centers[next] + 360 : centers[next]
            let test = index == centers.count - 1 ? "true" : "wrapped < \(high)"
            segments += """
                    \(index == 0 ? "" : "else ")if (\(test)) {
                        float t = clamp((wrapped - \(low)) / \(high - low), 0.0, 1.0);
                        adjustment = mix(b\(index), b\(next), t * t * (3.0 - 2.0 * t));
                    }

            """
        }
        return """
        float hslChannel(float t, float p, float q) {
            if (t < 0.0) { t += 1.0; }
            if (t > 1.0) { t -= 1.0; }
            if (t < 1.0 / 6.0) { return p + (q - p) * 6.0 * t; }
            if (t < 0.5) { return q; }
            if (t < 2.0 / 3.0) { return p + (q - p) * (2.0 / 3.0 - t) * 6.0; }
            return p;
        }

        kernel vec4 applyHSL(__sample c, vec3 b0, vec3 b1, vec3 b2, vec3 b3, vec3 b4, vec3 b5, vec3 b6, vec3 b7) {
            float maximum = max(c.r, max(c.g, c.b));
            float minimum = min(c.r, min(c.g, c.b));
            float chroma = maximum - minimum;
            // Greys have no hue and are left alone; the effect fades in as color gets stronger.
            if (chroma <= 0.000001) { return c; }

            float l = (maximum + minimum) * 0.5;
            float s = l > 0.5 ? chroma / (2.0 - maximum - minimum) : chroma / (maximum + minimum);
            float h;
            if (maximum == c.r) { h = (c.g - c.b) / chroma + (c.g < c.b ? 6.0 : 0.0); }
            else if (maximum == c.g) { h = (c.b - c.r) / chroma + 2.0; }
            else { h = (c.r - c.g) / chroma + 4.0; }
            h *= 60.0;

            // Blend between the two nearest bands; hue is 0…360 here, so the first segment starts at 0.
            float wrapped = h;
            vec3 adjustment = vec3(0.0);
        \(segments)
            float strength = smoothstep(0.02, 0.20, chroma);
            h += adjustment.x * 30.0 * strength;
            s = clamp(s * (1.0 + adjustment.y * strength), 0.0, 1.0);
            l = clamp(l + adjustment.z * 0.25 * strength, 0.0, 1.0);

            if (s <= 0.000000000001) { return vec4(l, l, l, c.a); }
            float hn = mod(h, 360.0) / 360.0;
            float q = l < 0.5 ? l * (1.0 + s) : l + s - l * s;
            float p = 2.0 * l - q;
            return vec4(hslChannel(hn + 1.0 / 3.0, p, q), hslChannel(hn, p, q), hslChannel(hn - 1.0 / 3.0, p, q), c.a);
        }
        """
    }()
}

enum HSLMethod: Sendable {
    /// Exact, per pixel.
    case kernel
    /// The interpolated color cube, kept for when the kernel cannot be compiled.
    case cube
}

extension MediaColorRenderer {
    private static let hslEncodingSpace = CGColorSpace(name: CGColorSpace.extendedSRGB)!

    /// HSL acts on sRGB-encoded color, where equal steps look equal. The image is converted from the
    /// working space and back without clamping.
    static func applyHSL(_ hsl: HSLAdjustments, to image: CIImage, method: HSLMethod = .kernel) -> CIImage {
        if method == .kernel,
           let encoded = image.matchedFromWorkingSpace(to: hslEncodingSpace),
           let applied = HSLColorKernel.apply(hsl, to: encoded),
           let linear = applied.matchedToWorkingSpace(from: hslEncodingSpace) {
            return linear
        }
        let cube = CIFilter.colorCubeWithColorSpace()
        cube.inputImage = image
        cube.cubeDimension = Float(ColorGrading.cubeDimension)
        cube.cubeData = ColorGrading.hslCube(hsl)
        cube.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        cube.extrapolate = true
        return cube.outputImage ?? image
    }
}
