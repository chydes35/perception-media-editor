import CoreGraphics
import Foundation

/// An editable starting point for the four Light controls. Other edits belong to the user.
struct AutoToneAdjustments: Equatable, Sendable {
    var exposure: Double
    var contrast: Double
    var highlights: Double
    var shadows: Double

    static let neutral = AutoToneAdjustments(exposure: 0, contrast: 0, highlights: 0, shadows: 0)

    func applying(to current: PhotoAdjustments) -> PhotoAdjustments {
        var result = current
        result.exposure = exposure
        result.contrast = contrast
        result.highlights = highlights
        result.shadows = shadows
        return result
    }

    func analysisBase(from current: PhotoAdjustments) -> PhotoAdjustments {
        Self.neutral.applying(to: current)
    }
}

enum PhotoAutoTone {
    /// Meter a small sRGB bitmap in linear light. Percentiles resist isolated bright lights,
    /// and transparent pixels do not bias the photograph toward black.
    static func analyze(_ image: CGImage) -> AutoToneAdjustments? {
        let scale = min(1, 256.0 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let linear = (0..<256).map { index -> Double in
            let value = Double(index) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        var histogram = [Double](repeating: 0, count: 1024)
        var total = 0.0
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let alpha = Int(bytes[offset + 3])
            guard alpha > 0 else { continue }
            let r = linear[min(255, Int(bytes[offset]) * 255 / alpha)]
            let g = linear[min(255, Int(bytes[offset + 1]) * 255 / alpha)]
            let b = linear[min(255, Int(bytes[offset + 2]) * 255 / alpha)]
            let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let weight = Double(alpha) / 255
            histogram[min(1023, Int(luminance * 1024))] += weight
            total += weight
        }
        guard total > 0 else { return nil }
        func percentile(_ fraction: Double) -> Double {
            var cumulative = 0.0
            for (index, count) in histogram.enumerated() {
                cumulative += count
                if cumulative >= fraction * total { return (Double(index) + 0.5) / 1024 }
            }
            return 1
        }
        let low = percentile(0.10)
        let median = percentile(0.50)
        let high = percentile(0.90)
        let white = percentile(0.98)
        // A completely clipped frame has no usable tonal information to recover here.
        if white <= 0.0005 || percentile(0.02) >= 0.995 { return .neutral }
        func bounded(_ value: Double, _ range: ClosedRange<Double>) -> Double {
            (min(range.upperBound, max(range.lowerBound, value)) * 100).rounded() / 100
        }
        // Move toward middle gray conservatively, limiting changes to 1.5 stops.
        var exposure = bounded(0.75 * log2(0.18 / max(0.01, median)), -1.5...1.5)
        if exposure > 0 {
            let headroom = log2(1.05 / max(0.001, white))
            exposure = min(exposure, max(0, headroom))
            if white >= 0.98 { exposure = min(exposure, 0.35) }
        }
        exposure = bounded(exposure, -1.5...1.5)
        let gain = pow(2, exposure)
        func encoded(_ luminance: Double) -> Double {
            luminance <= 0.0031308 ? 12.92 * luminance : 1.055 * pow(luminance, 1 / 2.4) - 0.055
        }
        let spread = encoded(high * gain) - encoded(low * gain)
        // CIColorControls contrast pivots around middle gray in the render pipeline.
        // On a very dark or bright frame it can undo the intended exposure move.
        let suggestedContrast = bounded((0.60 - spread) * 0.35, -0.15...0.20)
        return AutoToneAdjustments(
            exposure: exposure,
            contrast: abs(exposure) >= 0.5 ? 0 : suggestedContrast,
            highlights: bounded(-(white * gain - 0.75), -0.65...0),
            shadows: bounded((0.10 - low * gain) * 2.5, 0...0.35)
        )
    }
}
