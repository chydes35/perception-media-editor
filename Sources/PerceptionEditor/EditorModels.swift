import Foundation

enum Workspace: String, CaseIterable, Identifiable {
    case library = "Library"
    case photo = "Photo"
    case video = "Video"
    case export = "Export"

    var id: String { rawValue }
}

enum MediaKind: String, Codable, CaseIterable {
    case photo
    case video
    case audio
}

enum PreviewMode: String, CaseIterable, Identifiable, Sendable {
    case original = "Original"
    case edited = "Edited"
    case split = "Split"
    case sideBySide = "Side by Side"

    var id: String { rawValue }
}

struct HistogramData: Equatable, Sendable {
    var red: [Double]
    var green: [Double]
    var blue: [Double]

    static let empty = HistogramData(
        red: Array(repeating: 0, count: 256),
        green: Array(repeating: 0, count: 256),
        blue: Array(repeating: 0, count: 256)
    )

    var hasValues: Bool {
        red.contains(where: { $0 > 0 }) ||
            green.contains(where: { $0 > 0 }) ||
            blue.contains(where: { $0 > 0 })
    }
}

struct MediaAsset: Identifiable, Codable, Equatable {
    let id: UUID
    var url: URL
    var kind: MediaKind
    var importedAt: Date
    var rating: Int
    var isFavorite: Bool

    init(
        id: UUID = UUID(),
        url: URL,
        kind: MediaKind = .photo,
        importedAt: Date = .now,
        rating: Int = 0,
        isFavorite: Bool = false
    ) {
        self.id = id
        self.url = url
        self.kind = kind
        self.importedAt = importedAt
        self.rating = rating
        self.isFavorite = isFavorite
    }

    var filename: String { url.lastPathComponent }
}

enum CropAspect: String, Codable, CaseIterable, Identifiable, Sendable {
    case original = "Original"
    case square = "1:1"
    case portrait = "4:5"
    case photo = "3:2"
    case widescreen = "16:9"
    case vertical = "9:16"

    var id: String { rawValue }

    var ratio: CGFloat? {
        switch self {
        case .original: nil
        case .square: 1
        case .portrait: 4 / 5
        case .photo: 3 / 2
        case .widescreen: 16 / 9
        case .vertical: 9 / 16
        }
    }
}

struct PhotoAdjustments: Codable, Equatable, Sendable {
    var exposure = 0.0
    var contrast = 0.0
    var highlights = 0.0
    var shadows = 0.0
    var temperature = 0.0
    var tint = 0.0
    var vibrance = 0.0
    var saturation = 0.0
    var sharpness = 0.0
    var vignette = 0.0
    var rotationQuarterTurns = 0
    var cropAspect = CropAspect.original

    static let neutral = PhotoAdjustments()
}

struct PhotoPreset: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var category: String
    var adjustments: PhotoAdjustments

    init(
        id: UUID = UUID(),
        name: String,
        category: String,
        adjustments: PhotoAdjustments
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.adjustments = adjustments
    }

    static let builtIns: [PhotoPreset] = [
        PhotoPreset(
            name: "Documentary Warm",
            category: "Perception",
            adjustments: PhotoAdjustments(
                exposure: 0.10,
                contrast: 0.08,
                highlights: -0.18,
                shadows: 0.12,
                temperature: 0.14,
                saturation: -0.04,
                sharpness: 0.15,
                vignette: 0.08
            )
        ),
        PhotoPreset(
            name: "Interview Neutral",
            category: "Documentary",
            adjustments: PhotoAdjustments(
                highlights: -0.10,
                shadows: 0.08,
                vibrance: 0.08,
                sharpness: 0.10
            )
        ),
        PhotoPreset(
            name: "Restaurant Vibrant",
            category: "Business",
            adjustments: PhotoAdjustments(
                contrast: 0.12,
                temperature: 0.08,
                vibrance: 0.22,
                saturation: 0.08,
                sharpness: 0.14
            )
        ),
        PhotoPreset(
            name: "Quiet Monochrome",
            category: "Black & White",
            adjustments: PhotoAdjustments(
                contrast: 0.16,
                highlights: -0.12,
                shadows: 0.10,
                saturation: -1.0,
                sharpness: 0.10,
                vignette: 0.12
            )
        )
    ]
}

struct EditorProject: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion = currentSchemaVersion
    var id = UUID()
    var name: String
    var createdAt = Date.now
    var updatedAt = Date.now
    var media: [MediaAsset] = []
    var adjustmentsByAssetID: [UUID: PhotoAdjustments] = [:]

    static let starter = EditorProject(name: "Untitled Project")
}
