import CoreImage
import Foundation

/// Small-image color statistics shared by Auto and Look Match: 64 px sampling, neutral-color
/// evidence, the warmth/tint fit for that evidence, and luma percentiles. Results are plain
/// numbers; nothing here is stored in the project.
struct ImageStatistics {
    struct Pixel {
        var r: Double
        var g: Double
        var b: Double
        var x: Double
        var y: Double
        var luma: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    }

    let context: CIContext
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Opaque, finite sRGB samples on a grid whose longer side is 64 px. Positions are
    /// normalized with y measured from the bottom, as in Core Image.
    func pixels(_ image: CIImage) -> [Pixel] {
        let extent = image.extent
        guard extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0 else { return [] }
        let scale = 64 / max(extent.width, extent.height)
        let width = max(1, Int((extent.width * scale).rounded()))
        let height = max(1, Int((extent.height * scale).rounded()))
        let small = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        var buffer = [Float](repeating: 0, count: width * height * 4)
        context.render(small, toBitmap: &buffer, rowBytes: width * 16,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAf, colorSpace: space)
        return (0 ..< width * height).compactMap { index in
            let i = index * 4
            guard buffer[i + 3] > 0.95, buffer[i].isFinite,
                  buffer[i + 1].isFinite, buffer[i + 2].isFinite else { return nil }
            return Pixel(r: Double(buffer[i]), g: Double(buffer[i + 1]), b: Double(buffer[i + 2]),
                         x: (Double(index % width) + 0.5) / Double(width),
                         y: (Double(index / width) + 0.5) / Double(height))
        }
    }

    static func neutralReference(_ samples: [Pixel]) -> Pixel? {
        let candidates = samples.filter { p in
            let lo = min(p.r, p.g, p.b), hi = max(p.r, p.g, p.b)
            return p.luma > 0.28 && p.luma < 0.86 && lo > 0.1 && hi < 0.94 && hi / lo < 1.32
        }
        // Colored scenes and isolated bright objects are insufficient evidence for WB.
        guard candidates.count >= max(24, samples.count / 12) else { return nil }
        let cells = Set(candidates.map { Int($0.x * 3) + Int($0.y * 3) * 3 })
        guard cells.count >= 4 else { return nil }
        let r = median(candidates.map { log($0.r / $0.g) })
        let b = median(candidates.map { log($0.b / $0.g) })
        let consistent = candidates.filter {
            abs(log($0.r / $0.g) - r) < 0.06 && abs(log($0.b / $0.g) - b) < 0.06
        }
        guard consistent.count >= candidates.count / 2 else { return nil }
        let reference = consistent.min {
            abs(log($0.r / $0.g) - r) + abs(log($0.b / $0.g) - b)
                < abs(log($1.r / $1.g) - r) + abs(log($1.b / $1.g) - b)
        }!
        return Pixel(r: exp(r) * reference.g, g: reference.g, b: exp(b) * reference.g,
                     x: reference.x, y: reference.y)
    }

    /// Warmth and tint slider values that move `reference` most of the way to neutral.
    func fitWhiteBalance(_ reference: Pixel) -> (Double, Double) {
        guard let color = CIColor(red: reference.r, green: reference.g, blue: reference.b,
                                  colorSpace: space) else { return (0, 0) }
        let patch = CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        var best = PhotoAdjustments.neutral
        func loss(_ adjustments: PhotoAdjustments) -> Double {
            guard let p = pixels(MediaColorRenderer.render(patch, adjustments: adjustments, includesGeometry: false)).first,
                  min(p.r, p.g, p.b) > 0 else { return .infinity }
            return pow(log(p.r / p.g), 2) + pow(log(p.b / p.g), 2)
        }
        var score = loss(best)
        for step in [0.2, 0.1, 0.05, 0.025] {
            for key in [\PhotoAdjustments.temperature, \.tint] {
                for direction in [-1.0, 1.0] {
                    var trial = best
                    trial[keyPath: key] = Self.clamp(best[keyPath: key] + direction * step, -0.5, 0.5)
                    let value = loss(trial)
                    if value < score { best = trial; score = value }
                }
            }
        }
        // Preserve some lighting character rather than fully neutralizing every patch.
        return (Self.rounded(best.temperature * 0.75), Self.rounded(best.tint * 0.75))
    }

    static func colorCast(_ reference: Pixel) -> Double {
        pow(log(reference.r / reference.g), 2) + pow(log(reference.b / reference.g), 2)
    }

    /// The 10th, 50th, 90th and 99th luma percentiles of sorted values.
    static func quantiles(_ sorted: [Double]) -> [Double] {
        [0.10, 0.50, 0.90, 0.99].map { percentile(sorted, $0) }
    }

    /// The value at `fraction` of sorted, non-empty values (nearest rank, rounded down).
    static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        sorted[Int(Double(sorted.count - 1) * fraction)]
    }

    static func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
    static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double { min(high, max(low, value)) }
    static func rounded(_ value: Double) -> Double { (value * 100).rounded() / 100 }

    /// sRGB-encoded value to linear light.
    static func linear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
}
