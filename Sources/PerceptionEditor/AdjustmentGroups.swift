import Foundation

/// The sections of the Develop panel. Presets, copy and paste, and sync all work on groups, so
/// a preset that only sets tone leaves the photo's color, curve, and white balance alone.
enum AdjustmentGroup: String, CaseIterable, Codable, Identifiable, Sendable {
    case whiteBalance
    case tone
    case color
    case presence
    case toneCurve
    case hsl
    case rawDetail

    var id: String { rawValue }

    var title: String {
        switch self {
        case .whiteBalance: "White Balance"
        case .tone: "Light"
        case .color: "Color"
        case .presence: "Presence"
        case .toneCurve: "Tone Curve"
        case .hsl: "HSL"
        case .rawDetail: "RAW Detail"
        }
    }

    var detail: String {
        switch self {
        case .whiteBalance: "Temperature and tint"
        case .tone: "Exposure, contrast, highlights, shadows"
        case .color: "Warmth, tint, vibrance, saturation"
        case .presence: "Sharpness and vignette"
        case .toneCurve: "RGB and channel curves"
        case .hsl: "Hue, saturation, luminance by color"
        case .rawDetail: "Noise reduction, RAW sharpness, detail, lens corrections"
        }
    }

    /// What presets set unless told otherwise: everything except white balance, which belongs
    /// to the light a photo was taken in.
    static let looks: Set<AdjustmentGroup> = Set(allCases).subtracting([.whiteBalance])

    /// The groups the original four built-in presets, and presets saved before curves and HSL
    /// existed, change.
    static let basics: Set<AdjustmentGroup> = [.tone, .color, .presence]
}

extension PhotoAdjustments {
    /// A copy of this photo's settings with `groups` taken from `source`. Everything else,
    /// including crop and rotation, stays as it was.
    func applying(_ source: PhotoAdjustments, groups: Set<AdjustmentGroup>) -> PhotoAdjustments {
        var result = self
        for group in groups {
            switch group {
            case .whiteBalance:
                result.raw.temperature = source.raw.temperature
                result.raw.tint = source.raw.tint
            case .tone:
                result.exposure = source.exposure
                result.contrast = source.contrast
                result.highlights = source.highlights
                result.shadows = source.shadows
            case .color:
                result.temperature = source.temperature
                result.tint = source.tint
                result.vibrance = source.vibrance
                result.saturation = source.saturation
            case .presence:
                result.sharpness = source.sharpness
                result.vignette = source.vignette
            case .toneCurve:
                result.curves = source.curves
            case .hsl:
                result.hsl = source.hsl
            case .rawDetail:
                result.raw.luminanceNoiseReduction = source.raw.luminanceNoiseReduction
                result.raw.colorNoiseReduction = source.raw.colorNoiseReduction
                result.raw.sharpness = source.raw.sharpness
                result.raw.detail = source.raw.detail
                result.raw.lensCorrection = source.raw.lensCorrection
            }
        }
        return result
    }

    /// Only `groups` of these settings, on top of an untouched photo.
    func containing(_ groups: Set<AdjustmentGroup>) -> PhotoAdjustments {
        PhotoAdjustments().applying(self, groups: groups)
    }

    /// The groups in which this photo differs from an untouched one.
    var editedGroups: Set<AdjustmentGroup> {
        let untouched = PhotoAdjustments()
        return Set(AdjustmentGroup.allCases.filter { containing([$0]) != untouched })
    }

    /// A short description of what changed from `old`, such as "Exposure, Contrast +2 more".
    func changeSummary(from old: PhotoAdjustments) -> String {
        var names: [String] = []
        func note(_ name: String, _ changed: Bool) { if changed { names.append(name) } }

        note("Exposure", exposure != old.exposure)
        note("Contrast", contrast != old.contrast)
        note("Highlights", highlights != old.highlights)
        note("Shadows", shadows != old.shadows)
        note("White Balance", raw.temperature != old.raw.temperature || raw.tint != old.raw.tint)
        note("Warmth", temperature != old.temperature)
        note("Tint", tint != old.tint)
        note("Vibrance", vibrance != old.vibrance)
        note("Saturation", saturation != old.saturation)
        note("Sharpness", sharpness != old.sharpness)
        note("Vignette", vignette != old.vignette)
        note("Tone Curve", curves != old.curves)
        note("HSL", hsl != old.hsl)
        note("Noise Reduction", raw.luminanceNoiseReduction != old.raw.luminanceNoiseReduction
            || raw.colorNoiseReduction != old.raw.colorNoiseReduction)
        note("RAW Sharpness", raw.sharpness != old.raw.sharpness)
        note("Detail", raw.detail != old.raw.detail)
        note("Lens Corrections", raw.lensCorrection != old.raw.lensCorrection)
        note("Rotate", rotationQuarterTurns != old.rotationQuarterTurns)
        note("Crop", cropAspect != old.cropAspect || cropRect != old.cropRect)
        note("Straighten", straightenDegrees != old.straightenDegrees)

        switch names.count {
        case 0: return "No change"
        case 1, 2: return names.joined(separator: ", ")
        default: return "\(names[0]), \(names[1]) +\(names.count - 2) more"
        }
    }
}

/// One step in a photo's edit history for this session.
struct HistoryEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var date: Date
    /// The photo's settings after this step.
    var adjustments: PhotoAdjustments

    init(id: UUID = UUID(), name: String, date: Date = .now, adjustments: PhotoAdjustments) {
        self.id = id
        self.name = name
        self.date = date
        self.adjustments = adjustments
    }

    static let limit = 100
}

/// Settings copied with Copy Settings, ready to paste onto other photos.
struct CopiedSettings: Equatable, Sendable {
    var adjustments: PhotoAdjustments
    var groups: Set<AdjustmentGroup>
    var sourceName: String
}

// MARK: - Preset files

/// The on-disk form of exported presets (`.pmpreset`).
struct PresetFile: Codable, Equatable, Sendable {
    static let fileExtension = "pmpreset"
    static let currentFormat = 1

    var format = PresetFile.currentFormat
    var presets: [PhotoPreset]
}

enum PresetFileError: LocalizedError {
    case unsupportedFormat(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let version):
            "This preset file uses format \(version), which this version cannot read."
        }
    }
}

enum PresetLibrary {
    static let defaultCategory = "User"

    static func encode(_ presets: [PhotoPreset]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(PresetFile(presets: presets))
    }

    static func decode(_ data: Data) throws -> [PhotoPreset] {
        let file = try JSONDecoder().decode(PresetFile.self, from: data)
        guard file.format <= PresetFile.currentFormat else {
            throw PresetFileError.unsupportedFormat(file.format)
        }
        return file.presets
    }

    struct MergeResult: Equatable {
        var presets: [PhotoPreset]
        var added: Int
        var skipped: Int
    }

    /// Adds `incoming` presets to `existing`. An identical preset already in the library is
    /// skipped, and a different one with a name already in use gets "(2)", "(3)" after its name.
    static func merge(existing: [PhotoPreset], incoming: [PhotoPreset]) -> MergeResult {
        var result = existing
        var added = 0
        var skipped = 0

        for preset in incoming {
            let sameContent = result.contains {
                $0.name == preset.name && $0.category == preset.category
                    && $0.adjustments == preset.adjustments && $0.effectiveGroups == preset.effectiveGroups
            }
            if sameContent {
                skipped += 1
                continue
            }

            result.append(PhotoPreset(
                name: uniqueName(preset.name, category: preset.category, in: result),
                category: preset.category.isEmpty ? defaultCategory : preset.category,
                adjustments: preset.adjustments,
                groups: preset.groups
            ))
            added += 1
        }
        return MergeResult(presets: sorted(result), added: added, skipped: skipped)
    }

    static func uniqueName(_ name: String, category: String, in presets: [PhotoPreset]) -> String {
        func taken(_ candidate: String) -> Bool {
            presets.contains {
                $0.category == category && $0.name.localizedCaseInsensitiveCompare(candidate) == .orderedSame
            }
        }
        guard taken(name) else { return name }
        var number = 2
        while taken("\(name) (\(number))") { number += 1 }
        return "\(name) (\(number))"
    }

    static func sorted(_ presets: [PhotoPreset]) -> [PhotoPreset] {
        presets.sorted {
            if $0.category != $1.category {
                return $0.category.localizedCaseInsensitiveCompare($1.category) == .orderedAscending
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Category names in display order: the built-in ones first, then the user's own.
    static func categories(builtIn: [PhotoPreset], user: [PhotoPreset]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for category in builtIn.map(\.category) + user.map(\.category).sorted(by: {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }) where seen.insert(category).inserted {
            ordered.append(category)
        }
        return ordered
    }
}
