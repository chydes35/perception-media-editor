import CoreImage
import Foundation

/// A highlight shoulder for RAW photos. The RAW decode keeps highlights above white so that
/// exposure and highlight edits can recover them; without a shoulder every 8-bit output clipped
/// them, which blew out sunny frames by default. The curve maps a pixel's luminance, so brightness
/// always rises with the data, and scales the color to match. A channel that ends up above 0.9
/// is eased toward white instead of being pinned at it: the color is desaturated toward its own
/// luminance just enough, as a camera's rendering pales bright sky. Colors within 0–0.9 are untouched. Mapping the largest channel instead darkened bright blue
/// sky below its neighbours (a dark band on the 2026-10-18 shoot). Below `knee`, colors within
/// range are unchanged; above it the curve has slope 1 at the knee and reaches white exactly at
/// the white point (an extended Reinhard shoulder). On RAW photos the Highlights slider drives
/// this curve: lower values raise the white point (more highlight detail before white) and lower
/// the knee, so upper midtones ease down as with Lightroom's slider; higher values brighten
/// highlights.
enum HighlightRolloff {
    /// Linear value where the shoulder starts (about 80% in sRGB-encoded terms).
    static let knee = 0.6
    /// Linear value shown as white with Highlights at 0: two stops above white.
    static let baseWhite = 4.0
    private static let whiteRange = 1.05 ... 64.0

    /// Highlights −1 shows two more stops before white; +1 two stops fewer.
    static func whitePoint(highlights: Double) -> Double {
        min(whiteRange.upperBound, max(whiteRange.lowerBound, baseWhite * pow(2, -2 * highlights)))
    }

    /// Highlights −1 starts the shoulder at half the usual knee; positive values leave it alone.
    static func kneePoint(highlights: Double) -> Double {
        knee * (1 + 0.5 * min(0, max(-1, highlights)))
    }

    /// The shoulder for one linear luminance value. Values past the white point stay at 1.
    static func map(_ value: Double, white: Double, knee: Double = knee) -> Double {
        guard value > knee else { return value }
        let d = (value - knee) / (1 - knee)
        let w = (max(white, knee + 0.0001) - knee) / (1 - knee)
        return min(1, knee + (1 - knee) * d * (1 + d / (w * w)) / (1 + d))
    }

    /// A compiled color kernel is immutable and safe on Core Image's concurrent render queues.
    private final class Kernel: @unchecked Sendable {
        let value = CIColorKernel(source: """
            float shoulder(float x, float knee, float w) {
                if (x <= knee) { return x; }
                float d = (x - knee) / (1.0 - knee);
                return min(1.0, knee + (1.0 - knee) * d * (1.0 + d / (w * w)) / (1.0 + d));
            }
            kernel vec4 highlightRolloff(__sample s, float knee, float w) {
                float luminance = dot(s.rgb, vec3(0.2126, 0.7152, 0.0722));
                if (luminance <= 0.0001) { return s; }
                float mapped = shoulder(luminance, knee, w);
                vec3 c = s.rgb * (mapped / luminance);
                float m = max(max(c.r, c.g), c.b);
                if (m > 0.9) {
                    float limit = max(mapped, 0.9 + 0.1 * (1.0 - exp(-(m - 0.9) / 0.1)));
                    float k = (limit - mapped) / max(m - mapped, 0.0001);
                    c = vec3(mapped) + (c - vec3(mapped)) * k;
                }
                return vec4(c, s.a);
            }
            """)
    }
    private static let kernel = Kernel()

    static func apply(_ image: CIImage, highlights: Double) -> CIImage {
        apply(image, white: whitePoint(highlights: highlights), knee: kneePoint(highlights: highlights))
    }

    static func apply(_ image: CIImage, white: Double, knee: Double = knee) -> CIImage {
        guard let kernel = kernel.value else { return image }
        let w = (max(white, knee + 0.0001) - knee) / (1 - knee)
        return kernel.apply(extent: image.extent, arguments: [image, Float(knee), Float(w)]) ?? image
    }
}
