import Foundation

/// Develop settings that belong to the RAW decode itself. Changing one re-runs the decode
/// (about half a second on a 24 MP Lumix S5 file), unlike the tone and color adjustments,
/// which are applied to an already-decoded image. Every value is optional: nil means
/// "as the camera and the RAW engine would render it", so an untouched photo stores nothing.
struct RawSettings: Codable, Equatable, Sendable {
    /// White balance in Kelvin (2000–50000).
    var temperature: Double?
    /// White balance tint (−150 green … +150 magenta).
    var tint: Double?
    var luminanceNoiseReduction: Double?
    var colorNoiseReduction: Double?
    var sharpness: Double?
    /// Detail enhancement, 0–3.
    var detail: Double?
    var lensCorrection: Bool?

    /// Decode scene-linear data without the RAW engine's own tone curve, for process version 2. It is
    /// not stored in the project: it follows the photo's process version (`PhotoAdjustments.decodeSettings`).
    var sceneLinear = false

    private enum CodingKeys: String, CodingKey {
        case temperature, tint, luminanceNoiseReduction, colorNoiseReduction, sharpness, detail, lensCorrection
    }

    var isDefault: Bool {
        var copy = self
        copy.sceneLinear = false
        return copy == RawSettings()
    }

    var hasWhiteBalance: Bool { temperature != nil || tint != nil }

    var withoutWhiteBalance: RawSettings {
        var copy = self
        copy.temperature = nil
        copy.tint = nil
        return copy
    }

    /// A stable string identifying these settings, used to decide whether a cached decode is current.
    var cacheKey: String {
        func text(_ value: Double?) -> String { value.map { String(format: "%.4f", $0) } ?? "-" }
        return [
            text(temperature), text(tint), text(luminanceNoiseReduction), text(colorNoiseReduction),
            text(sharpness), text(detail), lensCorrection.map { $0 ? "1" : "0" } ?? "-",
            sceneLinear ? "scene" : "display"
        ].joined(separator: "|")
    }
}

/// What the RAW engine reports for one file, so the UI can show as-shot and default values.
struct RawInfo: Sendable, Equatable {
    var asShotTemperature: Double
    var asShotTint: Double
    var defaultLuminanceNoiseReduction: Double
    var defaultColorNoiseReduction: Double
    var defaultSharpness: Double
    var defaultDetail: Double
    var supportsNoiseReduction: Bool
    var supportsSharpness: Bool
    var supportsDetail: Bool
    var supportsLensCorrection: Bool
    var lensCorrectionDefault: Bool
}

/// Common white balance starting points, as in Lightroom's WB menu.
enum WhiteBalancePreset: String, CaseIterable, Identifiable, Sendable {
    case daylight = "Daylight"
    case cloudy = "Cloudy"
    case shade = "Shade"
    case tungsten = "Tungsten"
    case fluorescent = "Fluorescent"
    case flash = "Flash"

    var id: String { rawValue }

    var temperature: Double {
        switch self {
        case .daylight: 5500
        case .cloudy: 6500
        case .shade: 7500
        case .tungsten: 2850
        case .fluorescent: 3800
        case .flash: 5500
        }
    }

    var tint: Double {
        switch self {
        case .fluorescent: 21
        default: 0
        }
    }
}
