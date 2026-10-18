import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

// MARK: - Color grading

/// One tonal zone of a three-way grade: a tint (hue and strength) and a lightness shift.
struct GradeZone: Codable, Equatable, Sendable {
    /// Degrees, 0 … 360.
    var hue = 0.0
    /// 0 (no tint) … 1.
    var saturation = 0.0
    /// −1 … 1, worth up to ±0.25 of lightness.
    var luminance = 0.0

    var isNeutral: Bool { saturation == 0 && luminance == 0 }
}

/// Shadows, midtones, highlights and an overall tint, as in Lightroom's Color Grading panel.
struct ColorGradeAdjustments: Codable, Equatable, Sendable {
    var shadows = GradeZone()
    var midtones = GradeZone()
    var highlights = GradeZone()
    var global = GradeZone()
    /// 0 … 1: how far the zones overlap. Lightroom's default is 0.5.
    var blending = 0.5
    /// −1 … 1: moves the shadow/highlight boundary. Positive grows the highlights.
    var balance = 0.0

    var isNeutral: Bool {
        shadows.isNeutral && midtones.isNeutral && highlights.isNeutral && global.isNeutral
    }

    enum Zone: String, CaseIterable, Identifiable, Sendable {
        case shadows, midtones, highlights, global
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    subscript(zone: Zone) -> GradeZone {
        get {
            switch zone {
            case .shadows: shadows
            case .midtones: midtones
            case .highlights: highlights
            case .global: global
            }
        }
        set {
            switch zone {
            case .shadows: shadows = newValue
            case .midtones: midtones = newValue
            case .highlights: highlights = newValue
            case .global: global = newValue
            }
        }
    }
}

enum ColorGradeMath {
    /// How strongly a fully saturated zone shifts color.
    private static let tintStrength = 0.30
    private static let lightnessRange = 0.25

    private static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    /// How much of each zone applies at lightness `y` (0…1).
    static func weights(_ grade: ColorGradeAdjustments, lightness y: Double) -> (shadows: Double, midtones: Double, highlights: Double) {
        let spread = 0.15 + 0.35 * grade.blending
        let t = smoothstep(0.5 - spread, 0.5 + spread, y + grade.balance * 0.2)
        return (1 - t, 1 - abs(2 * t - 1), t)
    }

    /// One color after grading. Inputs and outputs are gamma-encoded RGB in 0…1.
    static func apply(_ grade: ColorGradeAdjustments, r: Double, g: Double, b: Double) -> (r: Double, g: Double, b: Double) {
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let w = weights(grade, lightness: y)
        var out = (r: r, g: g, b: b)

        func add(_ zone: GradeZone, weight: Double) {
            guard weight > 0, !zone.isNeutral else { return }
            let tint = ColorGrading.hslToRGB(zone.hue, 1, 0.5)
            let tintLuma = 0.2126 * tint.r + 0.7152 * tint.g + 0.0722 * tint.b
            let k = zone.saturation * tintStrength * weight
            let lift = zone.luminance * lightnessRange * weight
            out.r += (tint.r - tintLuma) * k + lift
            out.g += (tint.g - tintLuma) * k + lift
            out.b += (tint.b - tintLuma) * k + lift
        }
        add(grade.shadows, weight: w.shadows)
        add(grade.midtones, weight: w.midtones)
        add(grade.highlights, weight: w.highlights)
        add(grade.global, weight: 1)
        return (min(1, max(0, out.r)), min(1, max(0, out.g)), min(1, max(0, out.b)))
    }

    /// A color cube (RGBA floats, red varying fastest) that applies `grade`, for Core Image.
    static func cube(_ grade: ColorGradeAdjustments, dimension: Int = ColorGrading.cubeDimension) -> Data {
        if let cached = GradeCubeCache.shared.data(for: grade, dimension: dimension) { return cached }
        let n = dimension
        var values = [Float](repeating: 0, count: n * n * n * 4)
        var index = 0
        for blue in 0 ..< n {
            for green in 0 ..< n {
                for red in 0 ..< n {
                    let c = apply(grade, r: Double(red) / Double(n - 1), g: Double(green) / Double(n - 1), b: Double(blue) / Double(n - 1))
                    values[index] = Float(c.r)
                    values[index + 1] = Float(c.g)
                    values[index + 2] = Float(c.b)
                    values[index + 3] = 1
                    index += 4
                }
            }
        }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        GradeCubeCache.shared.store(data, for: grade, dimension: dimension)
        return data
    }
}

private final class GradeCubeCache: @unchecked Sendable {
    static let shared = GradeCubeCache()
    private let lock = NSLock()
    private var entries: [(grade: ColorGradeAdjustments, dimension: Int, data: Data)] = []

    func data(for grade: ColorGradeAdjustments, dimension: Int) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return entries.first { $0.grade == grade && $0.dimension == dimension }?.data
    }

    func store(_ data: Data, for grade: ColorGradeAdjustments, dimension: Int) {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll { $0.grade == grade && $0.dimension == dimension }
        entries.append((grade, dimension, data))
        if entries.count > 4 { entries.removeFirst(entries.count - 4) }
    }
}

// MARK: - Grain

/// Film grain, as in Lightroom's Effects panel. Nil on a photo when the amount is zero.
struct GrainAdjustments: Codable, Equatable, Sendable {
    /// 0 … 1.
    var amount = 0.0
    /// 0 (fine) … 1 (coarse). Lightroom's default is 0.25.
    var size = 0.25
    /// 0 (soft) … 1 (harsh). Lightroom's default is 0.5.
    var roughness = 0.5

    var isNeutral: Bool { amount == 0 }
}

extension MediaColorRenderer {
    private static let effectsEncodingSpace = CGColorSpace(name: CGColorSpace.extendedSRGB)!

    /// Three-way color grade through a color cube, on sRGB-encoded color.
    static func applyColorGrade(_ grade: ColorGradeAdjustments, to image: CIImage) -> CIImage {
        let cube = CIFilter.colorCubeWithColorSpace()
        cube.inputImage = image
        cube.cubeDimension = Float(ColorGrading.cubeDimension)
        cube.cubeData = ColorGradeMath.cube(grade)
        cube.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        cube.extrapolate = true
        return cube.outputImage ?? image
    }

    /// Monochrome grain soft-lit over the photo. The noise is anchored to the image's pixels, so
    /// it is the same on every render, and its cell size follows the photo's resolution so a
    /// preview and the full-size export look alike.
    static func applyGrain(_ grain: GrainAdjustments, to image: CIImage) -> CIImage {
        let extent = image.extent
        guard grain.amount > 0, !extent.isInfinite, !extent.isEmpty,
              let noise = CIFilter.randomGenerator().outputImage,
              let encoded = image.matchedFromWorkingSpace(to: effectsEncodingSpace) else { return image }

        let cell = (0.7 + grain.size * 2.8) * max(1, min(extent.width, extent.height) / 1500)
        let contrast = min(1.6, grain.amount * (0.5 + 1.1 * grain.roughness) * 1.6)
        // One noise channel in all three, scaled around mid-gray.
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = noise.transformed(by: CGAffineTransform(scaleX: cell, y: cell))
        matrix.rVector = CIVector(x: contrast, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: contrast, y: 0, z: 0, w: 0)
        matrix.bVector = CIVector(x: contrast, y: 0, z: 0, w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        let bias = 0.5 - 0.5 * contrast
        matrix.biasVector = CIVector(x: bias, y: bias, z: bias, w: 1)
        guard let gray = matrix.outputImage?.cropped(to: extent) else { return image }

        let blend = CIFilter.softLightBlendMode()
        blend.inputImage = gray
        blend.backgroundImage = encoded
        guard let blended = blend.outputImage?.cropped(to: extent),
              let result = blended.matchedToWorkingSpace(from: effectsEncodingSpace) else { return image }
        return result
    }
}
