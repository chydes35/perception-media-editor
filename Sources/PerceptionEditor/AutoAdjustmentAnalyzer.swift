import CoreImage
import Foundation

/// Suggestions are ordinary slider values. Analysis is never stored in the project.
struct AutoAdjustmentSuggestion: Equatable, Sendable {
    var basic = PhotoAdjustments.neutral
    var rawWhiteBalance: WhiteBalanceReading?

    func applying(to current: PhotoAdjustments) -> PhotoAdjustments {
        var result = current
        result.exposure = basic.exposure
        result.contrast = basic.contrast
        result.highlights = basic.highlights
        result.shadows = basic.shadows
        result.temperature = basic.temperature
        result.tint = basic.tint
        result.raw.temperature = rawWhiteBalance?.temperature
        result.raw.tint = rawWhiteBalance?.tint
        return result
    }
}

enum AutoAdjustmentError: LocalizedError {
    case unreadable
    var errorDescription: String? { "This photo could not be analyzed for Auto adjustments." }
}

/// Bounded decoding and fitting stay off the main actor and use a separate renderer.
actor AutoAdjustmentService {
    private let analyzer = AutoAdjustmentAnalyzer()
    func analyze(url: URL, current: PhotoAdjustments) throws -> AutoAdjustmentSuggestion {
        try analyzer.analyze(url: url, current: current)
    }
}

final class AutoAdjustmentAnalyzer {
    private let space = CGColorSpace(name: CGColorSpace.sRGB)!
    private lazy var context = CIContext(options: [.cacheIntermediates: false, .memoryTarget: 128])
    private struct Pixel {
        var r: Double
        var g: Double
        var b: Double
        var x: Double
        var y: Double
        var luma: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    }

    func analyze(url: URL, current: PhotoAdjustments) throws -> AutoAdjustmentSuggestion {
        try Task.checkCancellation()
        defer { context.clearCaches() }
        let raw = current.raw.withoutWhiteBalance
        guard let loaded = PhotoSourceLoader.load(url, maxDimension: 512, raw: raw) else {
            throw AutoAdjustmentError.unreadable
        }
        var source = try rasterized(loaded)
        var suggestion = AutoAdjustmentSuggestion()
        let neutral = neutralReference(pixels(source))
        if PhotoSourceLoader.isRAW(url) {
            // Use the camera-specific RAW calibration at a credible neutral patch.
            if let neutral, colorCast(neutral) > 0.0025,
               let reading = WhiteBalanceEyedropper.sampleRaw(
                   at: NormalizedPoint(x: neutral.x, y: 1 - neutral.y), url: url
               ), let info = PhotoSourceLoader.rawInfo(of: url) {
                let mired = 1_000_000 / info.asShotTemperature
                let change = clamp(1_000_000 / reading.temperature - mired, -35, 35) * 0.7
                suggestion.rawWhiteBalance = WhiteBalanceReading(
                    temperature: (1_000_000 / (mired + change)).rounded(),
                    tint: (info.asShotTint + clamp(reading.tint - info.asShotTint, -25, 25) * 0.7).rounded()
                )
                var balanced = raw
                balanced.temperature = suggestion.rawWhiteBalance?.temperature
                balanced.tint = suggestion.rawWhiteBalance?.tint
                guard let decoded = PhotoSourceLoader.load(url, maxDimension: 512, raw: balanced) else {
                    throw AutoAdjustmentError.unreadable
                }
                let balancedSource = try rasterized(decoded)
                if let checked = neutralReference(pixels(balancedSource)),
                   colorCast(checked) < colorCast(neutral) * 0.8 {
                    source = balancedSource
                } else {
                    // A downsampled patch may straddle colored texture. Retain as-shot WB
                    // unless the camera-calibrated correction improves the neutral evidence.
                    suggestion.rawWhiteBalance = nil
                }
            }
        } else if let neutral, colorCast(neutral) > 0.0025 {
            let wb = fitWhiteBalance(neutral)
            suggestion.basic.temperature = wb.0
            suggestion.basic.tint = wb.1
            source = MediaColorRenderer.render(source, adjustments: suggestion.basic, includesGeometry: false)
        }
        // Tone follows the visible crop, without compounding existing global/local edits.
        let visible = MediaColorRenderer.finishedGeometry(source, current)
        let tone = try fitTone(visible)
        suggestion.basic.exposure = tone.exposure
        suggestion.basic.contrast = tone.contrast
        suggestion.basic.highlights = tone.highlights
        suggestion.basic.shadows = tone.shadows
        return suggestion
    }

    /// Decoded-image entry point for reproducible image-quality tests.
    func suggest(for source: CIImage) throws -> AutoAdjustmentSuggestion {
        var suggestion = AutoAdjustmentSuggestion()
        var image = source
        if let neutral = neutralReference(pixels(image)), colorCast(neutral) > 0.0025 {
            let wb = fitWhiteBalance(neutral)
            suggestion.basic.temperature = wb.0
            suggestion.basic.tint = wb.1
            image = MediaColorRenderer.render(image, adjustments: suggestion.basic, includesGeometry: false)
        }
        let tone = try fitTone(image)
        suggestion.basic.exposure = tone.exposure
        suggestion.basic.contrast = tone.contrast
        suggestion.basic.highlights = tone.highlights
        suggestion.basic.shadows = tone.shadows
        return suggestion
    }

    private func pixels(_ image: CIImage) -> [Pixel] {
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

    /// CIImage graphs are lazy. Freeze the small decode once, otherwise each slider
    /// candidate can repeat RAW demosaicing. Half-float linear RGB retains highlight headroom.
    private func rasterized(_ image: CIImage) throws -> CIImage {
        guard let raster = context.createCGImage(image, from: image.extent, format: .RGBAh,
                                                colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)) else {
            throw AutoAdjustmentError.unreadable
        }
        return CIImage(cgImage: raster)
    }

    private func neutralReference(_ samples: [Pixel]) -> Pixel? {
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

    private func fitWhiteBalance(_ reference: Pixel) -> (Double, Double) {
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
                    trial[keyPath: key] = clamp(best[keyPath: key] + direction * step, -0.5, 0.5)
                    let value = loss(trial)
                    if value < score { best = trial; score = value }
                }
            }
        }
        // Preserve some lighting character rather than fully neutralizing every patch.
        return (rounded(best.temperature * 0.75), rounded(best.tint * 0.75))
    }

    private func colorCast(_ reference: Pixel) -> Double {
        pow(log(reference.r / reference.g), 2) + pow(log(reference.b / reference.g), 2)
    }

    private func fitTone(_ source: CIImage) throws -> PhotoAdjustments {
        let input = pixels(source).map(\.luma).sorted()
        guard input.count >= 16 else { throw AutoAdjustmentError.unreadable }
        let original = quantiles(input)
        let shift = clamp((0.48 - original[1]) * 0.65, -0.12, 0.12)
        let mid = original[1] + shift
        let flat = original[2] - original[0] < 0.35 ? 0.06 : 0.0
        let targets = [
            clamp(original[0] + shift * (original[0] > 0.1 ? 0.45 : 0.1) - flat,
                  0.015, max(0.02, mid - 0.10)),
            mid,
            clamp(original[2] + shift * 0.30 + flat, mid + 0.05, 0.95),
            min(0.99, original[3] + shift * 0.15)
        ]
        let scale = 64 / max(source.extent.width, source.extent.height)
        let small = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let baseline = pixels(small)
        let exposureRange: ClosedRange<Double> = original[1] < 0.35 ? 0.04 ... 1.4
            : original[1] > 0.65 ? -1.4 ... -0.04 : -1.4 ... 1.4
        func recentered(_ adjustments: PhotoAdjustments) -> PhotoAdjustments {
            var result = adjustments
            let output = pixels(MediaColorRenderer.render(small, adjustments: result, includesGeometry: false))
                .map(\.luma).sorted()
            guard !output.isEmpty else { return result }
            let current = output[output.count / 2]
            let ev = log2(max(0.0001, linear(mid)) / max(0.0001, linear(current)))
            result.exposure = clamp(result.exposure + ev, exposureRange.lowerBound, exposureRange.upperBound)
            return result
        }
        func loss(_ adjustments: PhotoAdjustments) -> Double {
            let samples = pixels(MediaColorRenderer.render(small, adjustments: adjustments, includesGeometry: false))
            let values = samples.map(\.luma).sorted()
            guard !values.isEmpty else { return .infinity }
            let q = quantiles(values)
            let weights = [1.0, 2.0, 1.0, 0.6]
            var result = zip(zip(q, targets), weights).reduce(0.0) { $0 + pow($1.0.0 - $1.0.1, 2) * $1.1 }
            result += 0.001 * (pow(adjustments.contrast, 2) + pow(adjustments.shadows, 2) + pow(adjustments.highlights, 2))
            // Tonal filters can also increase saturation. Penalize changes in linear RGB
            // chromaticity so a good luminance fit does not turn skin or scene colors vivid.
            var colorError = 0.0, count = 0.0
            for (before, after) in zip(baseline, samples) where before.luma > 0.08 && before.luma < 0.9 {
                let a = chromaticity(before), b = chromaticity(after)
                colorError += pow(a.0 - b.0, 2) + pow(a.1 - b.1, 2)
                count += 1
            }
            result += 20 * colorError / max(1, count)
            return result
        }
        var best = recentered(.neutral)
        var score = loss(best)
        let controls: [(WritableKeyPath<PhotoAdjustments, Double>, Double, Double, Double)] = [
            (\.contrast, 0, 0.35, 1),
            (\.highlights, -0.75, 0, 2), (\.shadows, 0, 0.6, 2)
        ]
        for step in [0.16, 0.08, 0.04, 0.02] {
            try Task.checkCancellation()
            for _ in 0 ..< 2 {
                for (key, lower, upper, multiplier) in controls {
                    for direction in [-1.0, 1.0] {
                        var trial = best
                        trial[keyPath: key] = clamp(best[keyPath: key] + direction * step * multiplier, lower, upper)
                        trial = recentered(trial)
                        let value = loss(trial)
                        if value < score { best = trial; score = value }
                    }
                }
            }
        }
        best.exposure = rounded(best.exposure)
        best.contrast = rounded(best.contrast)
        best.highlights = rounded(best.highlights)
        best.shadows = rounded(best.shadows)
        return best
    }

    private func quantiles(_ sorted: [Double]) -> [Double] {
        [0.10, 0.50, 0.90, 0.99].map { sorted[Int(Double(sorted.count - 1) * $0)] }
    }
    private func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
    private func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double { min(high, max(low, value)) }
    private func rounded(_ value: Double) -> Double { (value * 100).rounded() / 100 }
    private func linear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    private func chromaticity(_ pixel: Pixel) -> (Double, Double) {
        let r = max(0, linear(pixel.r)), g = max(0, linear(pixel.g)), b = max(0, linear(pixel.b))
        let sum = max(0.0001, r + g + b)
        return (r / sum, b / sum)
    }
}
