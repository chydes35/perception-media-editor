import Foundation

enum Workspace: String, CaseIterable, Identifiable {
    case library = "Library"
    case cull = "Cull"
    case photo = "Photo"
    case video = "Video"
    case export = "Export"
    case agents = "Agents"

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
    var flag: PhotoFlag
    var colorLabel: ColorLabel?
    /// EXIF capture time in the camera's local time, when the file has one.
    var captureDate: Date?
    var durationSeconds: Double?
    var pixelWidth: Int?
    var pixelHeight: Int?

    init(
        id: UUID = UUID(),
        url: URL,
        kind: MediaKind = .photo,
        importedAt: Date = .now,
        rating: Int = 0,
        isFavorite: Bool = false,
        flag: PhotoFlag = .unflagged,
        colorLabel: ColorLabel? = nil,
        captureDate: Date? = nil,
        durationSeconds: Double? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil
    ) {
        self.id = id
        self.url = url
        self.kind = kind
        self.importedAt = importedAt
        self.rating = rating
        self.isFavorite = isFavorite
        self.flag = flag
        self.colorLabel = colorLabel
        self.captureDate = captureDate
        self.durationSeconds = durationSeconds
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    private enum CodingKeys: String, CodingKey {
        case id, url, kind, importedAt, rating, isFavorite, flag, colorLabel, captureDate
        case durationSeconds, pixelWidth, pixelHeight
    }

    /// Fields added after schema 1 decode with defaults so older projects keep opening.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        url = try container.decode(URL.self, forKey: .url)
        kind = try container.decodeIfPresent(MediaKind.self, forKey: .kind) ?? .photo
        importedAt = try container.decodeIfPresent(Date.self, forKey: .importedAt) ?? .now
        rating = try container.decodeIfPresent(Int.self, forKey: .rating) ?? 0
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        flag = try container.decodeIfPresent(PhotoFlag.self, forKey: .flag) ?? .unflagged
        colorLabel = try container.decodeIfPresent(ColorLabel.self, forKey: .colorLabel)
        captureDate = try container.decodeIfPresent(Date.self, forKey: .captureDate)
        durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds)
        pixelWidth = try container.decodeIfPresent(Int.self, forKey: .pixelWidth)
        pixelHeight = try container.decodeIfPresent(Int.self, forKey: .pixelHeight)
    }

    var filename: String { url.lastPathComponent }
}

struct TimelineClip: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var assetID: UUID
    var videoTrack: Int
    var audioTrack: Int
    var timelineStartSeconds: Double
    var sourceStartSeconds: Double
    var durationSeconds: Double
    var isEnabled: Bool
    var isMuted: Bool

    init(
        id: UUID = UUID(),
        assetID: UUID,
        videoTrack: Int = 0,
        audioTrack: Int = 0,
        timelineStartSeconds: Double = 0,
        sourceStartSeconds: Double = 0,
        durationSeconds: Double,
        isEnabled: Bool = true,
        isMuted: Bool = false
    ) {
        self.id = id
        self.assetID = assetID
        self.videoTrack = videoTrack
        self.audioTrack = audioTrack
        self.timelineStartSeconds = timelineStartSeconds
        self.sourceStartSeconds = sourceStartSeconds
        self.durationSeconds = durationSeconds
        self.isEnabled = isEnabled
        self.isMuted = isMuted
    }
}

struct ClipAudioAdjustments: Codable, Equatable, Sendable {
    var volume = 1.0
    var pan = 0.0
    var fadeInSeconds = 0.0
    var fadeOutSeconds = 0.0

    static let neutral = ClipAudioAdjustments()
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

/// A normalized crop rectangle in image coordinates. The origin is bottom-left,
/// matching Core Image's coordinate system, and all values are clamped by the
/// crop editor before they are stored in the project.
struct CropRect: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let full = CropRect(x: 0, y: 0, width: 1, height: 1)
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
    var cropRect: CropRect? = nil
    var straightenDegrees: Double? = nil

    static let neutral = PhotoAdjustments()

    /// Tone and color only. Presets, look matching, and batch edits carry this part;
    /// crop, rotation, and straighten belong to an individual photo.
    var lookOnly: PhotoAdjustments {
        var look = self
        look.rotationQuarterTurns = 0
        look.cropAspect = .original
        look.cropRect = nil
        look.straightenDegrees = nil
        return look
    }

    /// This look applied to a photo while keeping that photo's own geometry.
    func look(keepingGeometryOf target: PhotoAdjustments) -> PhotoAdjustments {
        var result = lookOnly
        result.rotationQuarterTurns = target.rotationQuarterTurns
        result.cropAspect = target.cropAspect
        result.cropRect = target.cropRect
        result.straightenDegrees = target.straightenDegrees
        return result
    }

    /// Geometry without the crop, used while the crop editor is open so the whole
    /// frame is visible and the crop rectangle maps onto it directly.
    var withoutCrop: PhotoAdjustments {
        var uncropped = self
        uncropped.cropAspect = .original
        uncropped.cropRect = nil
        return uncropped
    }
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
    static let currentSchemaVersion = 5

    var schemaVersion = currentSchemaVersion
    var id = UUID()
    var name: String
    var createdAt = Date.now
    var updatedAt = Date.now
    var media: [MediaAsset] = []
    var adjustmentsByAssetID: [UUID: PhotoAdjustments] = [:]
    var videoAdjustmentsByClipID: [UUID: PhotoAdjustments] = [:]
    var audioAdjustmentsByClipID: [UUID: ClipAudioAdjustments] = [:]
    var timelineClips: [TimelineClip] = []

    static let starter = EditorProject(name: "Untitled Project")

    init(
        schemaVersion: Int = currentSchemaVersion,
        id: UUID = UUID(),
        name: String,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        media: [MediaAsset] = [],
        adjustmentsByAssetID: [UUID: PhotoAdjustments] = [:],
        videoAdjustmentsByClipID: [UUID: PhotoAdjustments] = [:],
        audioAdjustmentsByClipID: [UUID: ClipAudioAdjustments] = [:],
        timelineClips: [TimelineClip] = []
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.media = media
        self.adjustmentsByAssetID = adjustmentsByAssetID
        self.videoAdjustmentsByClipID = videoAdjustmentsByClipID
        self.audioAdjustmentsByClipID = audioAdjustmentsByClipID
        self.timelineClips = timelineClips
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case name
        case createdAt
        case updatedAt
        case media
        case adjustmentsByAssetID
        case videoAdjustmentsByClipID
        case audioAdjustmentsByClipID
        case timelineClips
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        media = try container.decodeIfPresent([MediaAsset].self, forKey: .media) ?? []
        adjustmentsByAssetID = try container.decodeIfPresent(
            [UUID: PhotoAdjustments].self,
            forKey: .adjustmentsByAssetID
        ) ?? [:]
        videoAdjustmentsByClipID = try container.decodeIfPresent(
            [UUID: PhotoAdjustments].self,
            forKey: .videoAdjustmentsByClipID
        ) ?? [:]
        audioAdjustmentsByClipID = try container.decodeIfPresent(
            [UUID: ClipAudioAdjustments].self,
            forKey: .audioAdjustmentsByClipID
        ) ?? [:]
        timelineClips = try container.decodeIfPresent([TimelineClip].self, forKey: .timelineClips) ?? []
    }
}
