import Foundation

enum PhotoFlag: String, Codable, CaseIterable, Identifiable, Sendable {
    case unflagged
    case picked
    case rejected

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unflagged: "Unflagged"
        case .picked: "Picked"
        case .rejected: "Rejected"
        }
    }
}

enum ColorLabel: String, Codable, CaseIterable, Identifiable, Sendable {
    case red
    case yellow
    case green
    case blue
    case purple

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// Which photos the library, culling view, and filmstrips show.
/// An empty set (or a zero rating) means "don't filter on this".
struct LibraryFilter: Equatable, Sendable {
    var flags: Set<PhotoFlag> = []
    var minimumRating = 0
    var colorLabels: Set<ColorLabel> = []

    var isActive: Bool {
        !flags.isEmpty || minimumRating > 0 || !colorLabels.isEmpty
    }

    func matches(_ asset: MediaAsset) -> Bool {
        if !flags.isEmpty, !flags.contains(asset.flag) { return false }
        if asset.rating < minimumRating { return false }
        if !colorLabels.isEmpty {
            guard let label = asset.colorLabel, colorLabels.contains(label) else { return false }
        }
        return true
    }
}

extension MediaAsset {
    /// When the photo was taken; falls back to when it was imported.
    var displayDate: Date { captureDate ?? importedAt }
}

enum CullCommand: Equatable, Sendable {
    case flag(PhotoFlag)
    case rating(Int)
    case toggleLabel(ColorLabel)
    case next
    case previous
    case toggleCompare
    case toggleFullScreen
    case openInDevelop
}

/// Lightroom's culling keys: P/X/U flag, 0–5 stars, 6–9 color labels, arrows navigate.
enum CullKeyMap {
    static let leftArrow = "\u{F702}"
    static let rightArrow = "\u{F703}"

    static func command(for characters: String) -> CullCommand? {
        switch characters.lowercased() {
        case "p": return .flag(.picked)
        case "x": return .flag(.rejected)
        case "u": return .flag(.unflagged)
        case "6": return .toggleLabel(.red)
        case "7": return .toggleLabel(.yellow)
        case "8": return .toggleLabel(.green)
        case "9": return .toggleLabel(.blue)
        case leftArrow: return .previous
        case rightArrow: return .next
        case "c": return .toggleCompare
        case "f": return .toggleFullScreen
        case "d", "\r": return .openInDevelop
        default:
            if characters.count == 1, let digit = Int(characters), (0 ... 5).contains(digit) {
                return .rating(digit)
            }
            return nil
        }
    }
}
