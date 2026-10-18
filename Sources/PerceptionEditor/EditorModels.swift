import Foundation

enum Workspace: String, CaseIterable, Identifiable {
    case library = "Library"
    case cull = "Cull"
    case photo = "Photo"
    case video = "Video"
    case videoColor = "Video Color"
    case videoAudio = "Video Audio"
    case videoExport = "Video Export"
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
    /// Video only (schema 11): the track's exact frame rate and frame count, filled in on import
    /// or when an older project opens.
    var frameRate: FrameRate?
    var frameCount: Int64?
    /// Video only (schema 11): what the original's code values mean (V-Log or Rec. 709, range, depth).
    var sourceColor: SourceColorDescriptor?

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
        pixelHeight: Int? = nil,
        frameRate: FrameRate? = nil,
        frameCount: Int64? = nil,
        sourceColor: SourceColorDescriptor? = nil
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
        self.frameRate = frameRate
        self.frameCount = frameCount
        self.sourceColor = sourceColor
    }

    private enum CodingKeys: String, CodingKey {
        case id, url, kind, importedAt, rating, isFavorite, flag, colorLabel, captureDate
        case durationSeconds, pixelWidth, pixelHeight, frameRate, frameCount, sourceColor
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
        frameRate = try container.decodeIfPresent(FrameRate.self, forKey: .frameRate)
        frameCount = try container.decodeIfPresent(Int64.self, forKey: .frameCount)
        sourceColor = try container.decodeIfPresent(SourceColorDescriptor.self, forKey: .sourceColor)
    }

    /// Frames in the source: the recorded count, or one derived from the duration for files whose
    /// metadata has not been read yet.
    var availableFrames: Int64? {
        if let frameCount { return frameCount }
        guard let durationSeconds, durationSeconds > 0 else { return nil }
        return (frameRate ?? .ntsc23976).nearestFrame(toSeconds: durationSeconds)
    }

    var filename: String { url.lastPathComponent }
}

/// One clip on the timeline. Edit points are whole frames (schema 11): `sourceStartFrame` and
/// `durationFrames` count in the clip's own `frameRate`; `timelineStartFrame` counts in the
/// project's sequence rate (`EditorProject.sequenceFrameRate`).
struct TimelineClip: Identifiable, Codable, Equatable, Sendable {
    /// The shortest clip a trim leaves (a quarter second at 23.976 fps).
    static let minimumFrames: Int64 = 6

    let id: UUID
    var assetID: UUID
    var videoTrack: Int
    var audioTrack: Int
    var frameRate: FrameRate
    var timelineStartFrame: Int64
    var sourceStartFrame: Int64
    var durationFrames: Int64
    var isEnabled: Bool
    var isMuted: Bool
    /// Seconds from a schema-10 project whose source has not been read yet. While set, the frame
    /// fields are a provisional 23.976 fps conversion; it is cleared once the real rate is known.
    var legacyTiming: LegacyClipTiming?

    init(
        id: UUID = UUID(),
        assetID: UUID,
        videoTrack: Int = 0,
        audioTrack: Int = 0,
        frameRate: FrameRate = .ntsc23976,
        timelineStartFrame: Int64 = 0,
        sourceStartFrame: Int64 = 0,
        durationFrames: Int64,
        isEnabled: Bool = true,
        isMuted: Bool = false
    ) {
        self.id = id
        self.assetID = assetID
        self.videoTrack = videoTrack
        self.audioTrack = audioTrack
        self.frameRate = frameRate
        self.timelineStartFrame = timelineStartFrame
        self.sourceStartFrame = sourceStartFrame
        self.durationFrames = durationFrames
        self.isEnabled = isEnabled
        self.isMuted = isMuted
    }

    var sourceStartSeconds: Double { frameRate.seconds(ofFrames: sourceStartFrame) }
    var durationSeconds: Double { frameRate.seconds(ofFrames: durationFrames) }

    /// Converts a schema-10 clip once its source's real frame rate is known.
    mutating func adoptFrameRate(_ rate: FrameRate) {
        guard let legacy = legacyTiming else { return }
        setFrames(from: legacy, rate: rate)
        legacyTiming = nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, assetID, videoTrack, audioTrack, isEnabled, isMuted
        case frameRate, timelineStartFrame, sourceStartFrame, durationFrames, legacyTiming
        // Schema 10 and earlier.
        case timelineStartSeconds, sourceStartSeconds, durationSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        assetID = try container.decode(UUID.self, forKey: .assetID)
        videoTrack = try container.decodeIfPresent(Int.self, forKey: .videoTrack) ?? 0
        audioTrack = try container.decodeIfPresent(Int.self, forKey: .audioTrack) ?? 0
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        if let frames = try container.decodeIfPresent(Int64.self, forKey: .durationFrames) {
            frameRate = try container.decode(FrameRate.self, forKey: .frameRate)
            durationFrames = frames
            sourceStartFrame = try container.decode(Int64.self, forKey: .sourceStartFrame)
            timelineStartFrame = try container.decode(Int64.self, forKey: .timelineStartFrame)
            legacyTiming = try container.decodeIfPresent(LegacyClipTiming.self, forKey: .legacyTiming)
        } else {
            let legacy = LegacyClipTiming(
                timelineStartSeconds: try container.decodeIfPresent(Double.self, forKey: .timelineStartSeconds) ?? 0,
                sourceStartSeconds: try container.decodeIfPresent(Double.self, forKey: .sourceStartSeconds) ?? 0,
                durationSeconds: try container.decode(Double.self, forKey: .durationSeconds)
            )
            frameRate = .ntsc23976
            timelineStartFrame = 0
            sourceStartFrame = 0
            durationFrames = 1
            legacyTiming = legacy
            setFrames(from: legacy, rate: .ntsc23976)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(assetID, forKey: .assetID)
        try container.encode(videoTrack, forKey: .videoTrack)
        try container.encode(audioTrack, forKey: .audioTrack)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(isMuted, forKey: .isMuted)
        try container.encode(frameRate, forKey: .frameRate)
        try container.encode(timelineStartFrame, forKey: .timelineStartFrame)
        try container.encode(sourceStartFrame, forKey: .sourceStartFrame)
        try container.encode(durationFrames, forKey: .durationFrames)
        // Unconverted clips keep their original seconds, so nothing is rounded twice.
        try container.encodeIfPresent(legacyTiming, forKey: .legacyTiming)
    }

    private mutating func setFrames(from legacy: LegacyClipTiming, rate: FrameRate) {
        frameRate = rate
        sourceStartFrame = max(0, rate.nearestFrame(toSeconds: legacy.sourceStartSeconds))
        durationFrames = max(1, rate.nearestFrame(toSeconds: legacy.durationSeconds))
        timelineStartFrame = max(0, rate.nearestFrame(toSeconds: legacy.timelineStartSeconds))
    }
}

/// Clip audio (schema 12). Loudness is gain in dB; schema 11 stored a 0…1 `volume`, which is read
/// once on open and converted (`decibels(forVolume:)`), and never written again.
struct ClipAudioAdjustments: Codable, Equatable, Sendable {
    static let minimumGainDecibels = -60.0
    static let maximumGainDecibels = 24.0
    static let gainRange = minimumGainDecibels...maximumGainDecibels

    /// −60…+24 dB. The −60 dB floor is silence (old volume 0 maps there).
    var gainDecibels = 0.0
    var pan = 0.0
    var fadeInSeconds = 0.0
    var fadeOutSeconds = 0.0

    static let neutral = ClipAudioAdjustments()

    init(gainDecibels: Double = 0, pan: Double = 0, fadeInSeconds: Double = 0, fadeOutSeconds: Double = 0) {
        self.gainDecibels = gainDecibels
        self.pan = pan
        self.fadeInSeconds = fadeInSeconds
        self.fadeOutSeconds = fadeOutSeconds
    }

    /// 20·log10(volume), clamped to the gain range; volume 0 (or anything under −60 dB) is the floor.
    static func decibels(forVolume volume: Double) -> Double {
        guard volume.isFinite, volume > 0 else { return minimumGainDecibels }
        return min(maximumGainDecibels, max(minimumGainDecibels, 20 * log10(volume)))
    }

    /// 10^(dB/20). The −60 dB floor (and below) is silence, so a migrated volume of 0 stays silent.
    static func linearGain(forDecibels decibels: Double) -> Double {
        guard decibels.isFinite, decibels > minimumGainDecibels else { return 0 }
        return pow(10, min(maximumGainDecibels, decibels) / 20)
    }

    /// The clip's linear gain in the mix.
    var linearGain: Double { Self.linearGain(forDecibels: gainDecibels) }

    private enum CodingKeys: String, CodingKey {
        case gainDecibels, pan, fadeInSeconds, fadeOutSeconds
        /// Schema 11 and earlier; decode only.
        case volume
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let gain = try container.decodeIfPresent(Double.self, forKey: .gainDecibels) {
            gainDecibels = min(Self.maximumGainDecibels, max(Self.minimumGainDecibels, gain))
        } else if let volume = try container.decodeIfPresent(Double.self, forKey: .volume) {
            // A volume above 1 was never valid (the old UI stopped at 1); clamp so a hand-edited file keeps its old loudness.
            gainDecibels = Self.decibels(forVolume: min(volume, 1))
        }
        pan = try container.decodeIfPresent(Double.self, forKey: .pan) ?? 0
        fadeInSeconds = try container.decodeIfPresent(Double.self, forKey: .fadeInSeconds) ?? 0
        fadeOutSeconds = try container.decodeIfPresent(Double.self, forKey: .fadeOutSeconds) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(gainDecibels, forKey: .gainDecibels)
        try container.encode(pan, forKey: .pan)
        try container.encode(fadeInSeconds, forKey: .fadeInSeconds)
        try container.encode(fadeOutSeconds, forKey: .fadeOutSeconds)
    }
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
    var raw = RawSettings()
    var curves = ToneCurves()
    /// Nil when every color band is untouched.
    var hsl: HSLAdjustments?
    /// Local adjustments, in order. Positions are in the original image's coordinates.
    var masks: [LocalMask] = []
    /// Photo-specific repairs in original-image coordinates.
    var retouches: [RetouchStroke] = []
    /// A creative LUT applied after the global adjustments (schema 11). It stays with its photo or
    /// clip: presets, copy and paste, and sync leave it alone.
    var lut: LUTApplication?

    static let neutral = PhotoAdjustments()

    /// Every look setting: tone, color, presence, curves, HSL, and RAW detail. Crop, rotation,
    /// straighten, and white balance belong to an individual photo, so they are left out.
    var lookOnly: PhotoAdjustments {
        containing(AdjustmentGroup.looks)
    }

    /// This look applied to a photo while keeping that photo's own geometry and white balance.
    func look(keepingGeometryOf target: PhotoAdjustments) -> PhotoAdjustments {
        target.applying(self, groups: AdjustmentGroup.looks)
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

extension PhotoAdjustments {
    enum CodingKeys: String, CodingKey {
        case exposure, contrast, highlights, shadows, temperature, tint, vibrance, saturation
        case sharpness, vignette, rotationQuarterTurns, cropAspect, cropRect, straightenDegrees, raw, curves, hsl, masks, retouches, lut
    }

    /// Every field decodes with a default, so projects saved before a field existed still open.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        exposure = try container.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        contrast = try container.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        highlights = try container.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        shadows = try container.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? 0
        tint = try container.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        vibrance = try container.decodeIfPresent(Double.self, forKey: .vibrance) ?? 0
        saturation = try container.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        sharpness = try container.decodeIfPresent(Double.self, forKey: .sharpness) ?? 0
        vignette = try container.decodeIfPresent(Double.self, forKey: .vignette) ?? 0
        rotationQuarterTurns = try container.decodeIfPresent(Int.self, forKey: .rotationQuarterTurns) ?? 0
        cropAspect = try container.decodeIfPresent(CropAspect.self, forKey: .cropAspect) ?? .original
        cropRect = try container.decodeIfPresent(CropRect.self, forKey: .cropRect)
        straightenDegrees = try container.decodeIfPresent(Double.self, forKey: .straightenDegrees)
        raw = try container.decodeIfPresent(RawSettings.self, forKey: .raw) ?? RawSettings()
        curves = try container.decodeIfPresent(ToneCurves.self, forKey: .curves) ?? ToneCurves()
        hsl = try container.decodeIfPresent(HSLAdjustments.self, forKey: .hsl)
        masks = try container.decodeIfPresent([LocalMask].self, forKey: .masks) ?? []
        retouches = try container.decodeIfPresent([RetouchStroke].self, forKey: .retouches) ?? []
        lut = try container.decodeIfPresent(LUTApplication.self, forKey: .lut)
    }
}

struct PhotoPreset: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var category: String
    var adjustments: PhotoAdjustments
    /// The groups this preset sets. Nil for presets saved before groups existed, which set
    /// tone, color, and presence.
    var groups: Set<AdjustmentGroup>?

    init(
        id: UUID = UUID(),
        name: String,
        category: String,
        adjustments: PhotoAdjustments,
        groups: Set<AdjustmentGroup>? = nil
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.adjustments = adjustments
        self.groups = groups
    }

    var effectiveGroups: Set<AdjustmentGroup> { groups ?? AdjustmentGroup.basics }

    /// `target` with this preset's groups applied; everything else about the photo is kept.
    func apply(to target: PhotoAdjustments) -> PhotoAdjustments {
        target.applying(adjustments, groups: effectiveGroups)
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
    static let currentSchemaVersion = 12

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
    /// Per media item (schema 11); a missing entry means `.automatic`.
    var colorInputByAssetID: [UUID: ColorInputTransform] = [:]
    /// Schema 12: applied to the whole mix on top of each clip's gain. Missing in older files means 0 dB.
    var masterGainDecibels = 0.0

    static let starter = EditorProject(name: "Untitled Project")

    /// The rate timeline positions count in: the first clip's rate. Every edit re-packs the
    /// timeline in this rate, so it stays consistent when the first clip changes.
    var sequenceFrameRate: FrameRate { timelineClips.first?.frameRate ?? .ntsc23976 }

    /// How many sequence frames a clip occupies.
    func timelineFrames(of clip: TimelineClip) -> Int64 {
        clip.frameRate.frames(clip.durationFrames, in: sequenceFrameRate)
    }

    func timelineStartSeconds(of clip: TimelineClip) -> Double {
        sequenceFrameRate.seconds(ofFrames: clip.timelineStartFrame)
    }

    /// Packs the clips end to end in sequence frames.
    mutating func packTimeline() {
        var cursor: Int64 = 0
        for index in timelineClips.indices {
            timelineClips[index].timelineStartFrame = cursor
            cursor += timelineFrames(of: timelineClips[index])
        }
    }

    /// Every LUT the project uses: creative LUTs on photos and clips, and source-color LUTs.
    var referencedLUTs: Set<LUTReference> {
        var references = Set<LUTReference>()
        for adjustments in adjustmentsByAssetID.values { if let lut = adjustments.lut { references.insert(lut.reference) } }
        for adjustments in videoAdjustmentsByClipID.values { if let lut = adjustments.lut { references.insert(lut.reference) } }
        for input in colorInputByAssetID.values { if case .lut(let reference) = input { references.insert(reference) } }
        return references
    }

    func colorInput(for assetID: UUID) -> ColorInputTransform {
        colorInputByAssetID[assetID] ?? .automatic
    }

    var timelineDurationFrames: Int64 {
        timelineClips.map { $0.timelineStartFrame + timelineFrames(of: $0) }.max() ?? 0
    }

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
        case colorInputByAssetID
        case masterGainDecibels
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
        colorInputByAssetID = try container.decodeIfPresent(
            [UUID: ColorInputTransform].self,
            forKey: .colorInputByAssetID
        ) ?? [:]
        let masterGain = try container.decodeIfPresent(Double.self, forKey: .masterGainDecibels) ?? 0
        masterGainDecibels = min(ClipAudioAdjustments.maximumGainDecibels, max(ClipAudioAdjustments.minimumGainDecibels, masterGain))
    }
}
