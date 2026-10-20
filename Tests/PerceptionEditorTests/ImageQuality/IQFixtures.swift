import CoreImage
import Foundation

/// Synthetic test scenes generated in code, in extended-linear sRGB, so no binary fixtures are
/// needed and every pixel value is known.
enum IQFixtures {
    static let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    static func image(width: Int, height: Int, _ pixel: (Int, Int) -> (Float, Float, Float)) -> CIImage {
        var data = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = pixel(x, y)
                let offset = (y * width + x) * 4
                data[offset] = r; data[offset + 1] = g; data[offset + 2] = b
            }
        }
        let bytes = data.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: bytes, bytesPerRow: width * 16, size: CGSize(width: width, height: height),
                       format: .RGBAf, colorSpace: linearSpace)
    }

    /// Neutral ramp, logarithmic from 2⁻¹⁰ to 2⁴ in linear light (scene values above white included).
    static func grayRamp() -> CIImage {
        image(width: 256, height: 32) { x, _ in
            let v = Float(pow(2.0, -10 + 14 * Double(x) / 255))
            return (v, v, v)
        }
    }

    /// Highlight ramp 0.5…16 in linear light, for roll-off smoothness.
    static func highlightRamp() -> CIImage {
        image(width: 256, height: 32) { x, _ in
            let v = Float(0.5 * pow(32.0, Double(x) / 255))
            return (v, v, v)
        }
    }

    /// The 24 ColorChecker patches (common sRGB approximations), 6 × 4 grid of 32 px squares.
    static let colorCheckerSRGB: [(Double, Double, Double)] = [
        (115, 82, 68), (194, 150, 130), (98, 122, 157), (87, 108, 67), (133, 128, 177), (103, 189, 170),
        (214, 126, 44), (80, 91, 166), (193, 90, 99), (94, 60, 108), (157, 188, 64), (224, 163, 46),
        (56, 61, 150), (70, 148, 73), (175, 54, 60), (231, 199, 31), (187, 86, 149), (8, 133, 161),
        (243, 243, 242), (200, 200, 200), (160, 160, 160), (122, 122, 121), (85, 85, 85), (52, 52, 52),
    ].map { ($0.0 / 255, $0.1 / 255, $0.2 / 255) }

    static func colorChecker() -> CIImage {
        image(width: 192, height: 128) { x, y in
            let patch = colorCheckerSRGB[(y / 32) * 6 + x / 32]
            return (Float(IQMetrics.srgbToLinear(patch.0)), Float(IQMetrics.srgbToLinear(patch.1)),
                    Float(IQMetrics.srgbToLinear(patch.2)))
        }
    }

    /// Hue sweep at three saturations and two lightnesses, to expose hue shifts and gamut clipping.
    static func gamutSweep() -> CIImage {
        image(width: 256, height: 64) { x, y in
            let hue = Double(x) / 256
            let saturation = [1.0, 0.6, 0.25][min(2, y / 22)]
            let value = y % 2 == 0 ? 0.85 : 0.45
            let (r, g, b) = hsv(hue, saturation, value)
            return (Float(IQMetrics.srgbToLinear(r)), Float(IQMetrics.srgbToLinear(g)), Float(IQMetrics.srgbToLinear(b)))
        }
    }

    /// Skin-tone patches from light to dark, warm to cool.
    static func skinTones() -> CIImage {
        let tones: [(Double, Double, Double)] = [
            (255, 224, 196), (241, 194, 160), (224, 172, 135), (198, 134, 96),
            (166, 108, 76), (141, 85, 58), (104, 64, 44), (74, 44, 32),
        ].map { ($0.0 / 255, $0.1 / 255, $0.2 / 255) }
        return image(width: 256, height: 32) { x, _ in
            let tone = tones[x / 32]
            return (Float(IQMetrics.srgbToLinear(tone.0)), Float(IQMetrics.srgbToLinear(tone.1)),
                    Float(IQMetrics.srgbToLinear(tone.2)))
        }
    }

    /// Radial zone plate, for resolution-dependent filters (sharpening, local contrast).
    static func zonePlate() -> CIImage {
        image(width: 128, height: 128) { x, y in
            let dx = Double(x) - 64, dy = Double(y) - 64
            let v = 0.18 * (1 + 0.8 * cos(0.0035 * (dx * dx + dy * dy)))
            return (Float(v), Float(v), Float(v))
        }
    }

    static let all: [(name: String, make: @Sendable () -> CIImage)] = [
        ("grayRamp", grayRamp), ("highlightRamp", highlightRamp), ("colorChecker", colorChecker),
        ("gamutSweep", gamutSweep), ("skinTones", skinTones), ("zonePlate", zonePlate),
    ]

    private static func hsv(_ h: Double, _ s: Double, _ v: Double) -> (Double, Double, Double) {
        let i = Int(h * 6) % 6
        let f = h * 6 - floor(h * 6)
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        switch i {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }
}
