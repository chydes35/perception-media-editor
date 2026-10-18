import Foundation

/// Reads a Lightroom / Camera Raw develop preset (`.xmp`) and maps the settings Perception
/// Edit has onto a `PhotoPreset`. Settings with no counterpart here are listed, not guessed.
enum LightroomPresetImporter {
    struct Result: Equatable {
        var preset: PhotoPreset
        /// Camera Raw settings in the file that Perception Edit has no equivalent for.
        var unsupported: [String]
    }

    enum ImportError: LocalizedError {
        case notAPreset
        case noSupportedSettings
        case colorTableOnly

        var errorDescription: String? {
            switch self {
            case .notAPreset: "Not a Lightroom or Camera Raw preset."
            case .noSupportedSettings: "None of this preset's settings are supported."
            case .colorTableOnly: "This look is built from an embedded color table (LUT), which can't be imported yet."
            }
        }
    }

    static let fileExtension = "xmp"

    static func importPreset(from data: Data, fallbackName: String) throws -> Result {
        let parsed = try XMPSettings.parse(data)
        guard parsed.values.keys.contains(where: { $0 != "Name" && $0 != "Group" }) || !parsed.lists.isEmpty else {
            throw ImportError.notAPreset
        }

        var adjustments = PhotoAdjustments()
        var groups = Set<AdjustmentGroup>()
        var handled = Set<String>()

        func number(_ key: String) -> Double? {
            guard let text = parsed.values[key] else { return nil }
            handled.insert(key)
            return Double(text.replacingOccurrences(of: "+", with: ""))
        }
        func scaled(_ key: String, divisor: Double = 100, range: ClosedRange<Double> = -1 ... 1) -> Double? {
            number(key).map { min(range.upperBound, max(range.lowerBound, $0 / divisor)) }
        }

        // Light
        if let value = number("Exposure2012") { adjustments.exposure = min(3, max(-3, value)) }
        adjustments.contrast = scaled("Contrast2012") ?? 0
        adjustments.highlights = scaled("Highlights2012") ?? 0
        adjustments.shadows = scaled("Shadows2012") ?? 0
        if adjustments.exposure != 0 || adjustments.contrast != 0
            || adjustments.highlights != 0 || adjustments.shadows != 0 {
            groups.insert(.tone)
        }

        // Color
        adjustments.vibrance = scaled("Vibrance") ?? 0
        adjustments.saturation = scaled("Saturation") ?? 0
        if parsed.values["ConvertToGrayscale"]?.lowercased() == "true" {
            handled.insert("ConvertToGrayscale")
            adjustments.saturation = -1
        }
        if adjustments.vibrance != 0 || adjustments.saturation != 0 { groups.insert(.color) }

        // Presence
        adjustments.sharpness = scaled("Sharpness", divisor: 150, range: 0 ... 1) ?? 0
        if let vignette = scaled("PostCropVignetteAmount") { adjustments.vignette = max(0, -vignette) }
        if adjustments.sharpness != 0 || adjustments.vignette != 0 { groups.insert(.presence) }

        // Tone curves
        for (key, channel) in [
            ("ToneCurvePV2012", ToneCurves.Channel.rgb), ("ToneCurvePV2012Red", .red),
            ("ToneCurvePV2012Green", .green), ("ToneCurvePV2012Blue", .blue)
        ] {
            guard let items = parsed.lists[key] else { continue }
            handled.insert(key)
            if let curve = toneCurve(from: items), !curve.isLinear {
                adjustments.curves[channel] = curve
                groups.insert(.toneCurve)
            }
        }

        // HSL
        var hsl = HSLAdjustments()
        for (band, name) in [
            (HSLBand.red, "Red"), (.orange, "Orange"), (.yellow, "Yellow"), (.green, "Green"),
            (.aqua, "Aqua"), (.blue, "Blue"), (.purple, "Purple"), (.magenta, "Magenta")
        ] {
            let adjustment = HSLBandAdjustment(
                hue: scaled("HueAdjustment\(name)") ?? 0,
                saturation: scaled("SaturationAdjustment\(name)") ?? 0,
                luminance: scaled("LuminanceAdjustment\(name)") ?? 0
            )
            switch band {
            case .red: hsl.red = adjustment
            case .orange: hsl.orange = adjustment
            case .yellow: hsl.yellow = adjustment
            case .green: hsl.green = adjustment
            case .aqua: hsl.aqua = adjustment
            case .blue: hsl.blue = adjustment
            case .purple: hsl.purple = adjustment
            case .magenta: hsl.magenta = adjustment
            }
        }
        if !hsl.isNeutral {
            adjustments.hsl = hsl
            groups.insert(.hsl)
        }

        // Noise reduction (applies at RAW decode)
        let luminanceNR = scaled("LuminanceSmoothing", range: 0 ... 1) ?? 0
        let colorNR = scaled("ColorNoiseReduction", range: 0 ... 1) ?? 0
        if luminanceNR > 0 || colorNR > 0 {
            adjustments.raw.luminanceNoiseReduction = luminanceNR
            adjustments.raw.colorNoiseReduction = colorNR
            groups.insert(.rawDetail)
        }

        guard !groups.isEmpty else {
            throw parsed.values["RGBTable"] != nil ? ImportError.colorTableOnly : ImportError.noSupportedSettings
        }

        let name = parsed.values["Name"].flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
        let category = parsed.values["Group"].flatMap { $0.isEmpty ? nil : $0 } ?? "Imported"
        let preset = PhotoPreset(name: name, category: category, adjustments: adjustments, groups: groups)
        return Result(preset: preset, unsupported: unsupportedSettings(in: parsed, handled: handled))
    }

    // MARK: - Mapping helpers

    /// Camera Raw curves run 0…255 in both axes and may start at x = 1 or end before 255.
    static func toneCurve(from items: [String]) -> ToneCurve? {
        var points: [CurvePoint] = items.compactMap { item in
            let parts = item.split(separator: ",").compactMap {
                Double($0.trimmingCharacters(in: .whitespaces))
            }
            guard parts.count == 2 else { return nil }
            return CurvePoint(x: min(1, max(0, parts[0] / 255)), y: min(1, max(0, parts[1] / 255)))
        }
        points.sort { $0.x < $1.x }
        guard points.count >= 2 else { return nil }
        points[0].x = 0
        points[points.count - 1].x = 1

        // Keep the editor's invariants: spacing between points and a point cap.
        var kept = [points[0]]
        for point in points.dropFirst().dropLast() where
            point.x - kept[kept.count - 1].x >= ToneCurve.minimumGap
            && 1 - point.x >= ToneCurve.minimumGap {
            kept.append(point)
        }
        kept.append(points[points.count - 1])
        while kept.count > ToneCurve.maximumPoints {
            kept.remove(at: kept.count / 2)
        }
        return ToneCurve(points: kept)
    }

    /// Setting names with a non-default value that nothing above consumed.
    private static func unsupportedSettings(in parsed: XMPSettings, handled: Set<String>) -> [String] {
        let metadata: Set<String> = [
            "PresetType", "Cluster", "UUID", "SupportsAmount", "SupportsColor", "SupportsMonochrome",
            "SupportsHighDynamicRange", "SupportsNormalDynamicRange", "SupportsSceneReferred",
            "SupportsOutputReferred", "RequiresRGBTables", "CameraModelRestriction", "Copyright",
            "ContactInfo", "Version", "ProcessVersion", "HasSettings", "Name", "ShortName",
            "SortName", "Group", "Description", "ToneCurveName2012", "OverrideLookVignette",
            "AutoLateralCA", "ColorGradeBlending", "ColorGradeGlobalHue", "ColorGradeGlobalSat", "SharpenRadius", "SharpenDetail", "SharpenEdgeMasking", "ColorNoiseReductionDetail",
            "ColorNoiseReductionSmoothness", "ParametricShadowSplit", "ParametricMidtoneSplit",
            "ParametricHighlightSplit", "GrainSize", "GrainFrequency", "WhiteBalance"
        ]
        let neutral: Set<String> = ["0", "+0", "0.00", "+0.00", "0.0", "False", "false", ""]
        let ignoredPrefixes = ["Defringe", "Table_", "CameraProfile", "Lens", "Perspective", "Incremental"]
        let changed = parsed.values.filter { key, value in
            !handled.contains(key) && !metadata.contains(key) && !neutral.contains(value)
                && !ignoredPrefixes.contains(where: key.hasPrefix) && value.count < 64
        }.keys
        // Whites/Blacks/Clarity/Texture/Dehaze, grain, split toning, parametric curve, white balance.
        var names = Array(changed)
        if parsed.values["WhiteBalance"] == "Custom" { names.append("WhiteBalance") }
        return names.sorted()
    }
}

// MARK: - XMP reading

/// The `crs:` settings of one XMP file: attribute values, plain-text elements (name, group),
/// and ordered lists (tone curves).
struct XMPSettings {
    var values: [String: String] = [:]
    var lists: [String: [String]] = [:]

    static func parse(_ data: Data) throws -> XMPSettings {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() else { throw LightroomPresetImporter.ImportError.notAPreset }
        return reader.settings
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var settings = XMPSettings()
        private var currentElement: String?
        private var listItems: [String] = []
        private var text = ""
        private var inItem = false

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?, attributes attributeDict: [String: String]
        ) {
            if elementName == "rdf:Description" {
                for (key, value) in attributeDict where key.hasPrefix("crs:") {
                    settings.values[String(key.dropFirst(4))] = value
                }
            } else if elementName.hasPrefix("crs:") {
                currentElement = String(elementName.dropFirst(4))
                listItems = []
            } else if elementName == "rdf:li" {
                inItem = true
                text = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inItem { text += string }
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            if elementName == "rdf:li" {
                inItem = false
                listItems.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
            } else if elementName.hasPrefix("crs:"), let name = currentElement, name == String(elementName.dropFirst(4)) {
                if ["Name", "ShortName", "SortName", "Group", "Description", "ToneCurveName2012"].contains(name) {
                    settings.values[name] = listItems.first(where: { !$0.isEmpty }) ?? ""
                } else {
                    settings.lists[name] = listItems
                }
                currentElement = nil
            }
        }
    }
}
