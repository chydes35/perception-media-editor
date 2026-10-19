import CoreImage
import Foundation

/// One photo as the store saw it when Look Match started.
struct LookMatchPhoto: Sendable, Equatable {
    var id: UUID
    var url: URL
    var adjustments: PhotoAdjustments
}

struct LookMatchRequest: Sendable, Equatable {
    var photos: [LookMatchPhoto]
    var selectedID: UUID?
    var thresholds = LookMatchThresholds.default
}

struct LookMatchProposal: Sendable, Equatable {
    var targetID: UUID
    var heroID: UUID
    var adjustments: PhotoAdjustments
    var confidence: Double
    var isFlagged: Bool
}

struct LookMatchScene: Sendable, Equatable {
    var index: Int
    /// Photos in capture order.
    var assetIDs: [UUID]
    var heroID: UUID?
    /// Set only when the scene has no edited photo: the frame to edit first.
    var suggestedHeroID: UUID?
    var proposals: [LookMatchProposal] = []
    var alreadyEdited: [UUID] = []
    var unreadable: [UUID] = []
    /// Why this scene starts where it does (empty for the first scene), for tuning thresholds.
    var splitReasons: [String] = []
}

/// Analysis results. Never stored in the project.
struct LookMatchResult: Sendable, Equatable {
    var scenes: [LookMatchScene]
}

enum LookMatchError: LocalizedError {
    case unreadable
    var errorDescription: String? { "This photo could not be analyzed for Look Match." }
}

/// Runs Look Match off the main actor and away from the preview renderer.
///
/// Analysis blocks inside RAW decoding and Vision. Swift's cooperative threads must not
/// block: with enough analyses at once, every cooperative thread waited on Vision and nothing
/// else could run (a deadlock seen on 2026-10-19). The actor therefore runs on its own
/// serial dispatch queue, whose thread may block without starving the rest of the app.
actor LookMatchService {
    private let queue = DispatchSerialQueue(label: "com.perceptionmedia.editor.look-match", qos: .userInitiated)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    private let analyzer = LookMatchAnalyzer()
    func analyze(_ request: LookMatchRequest,
                 progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) throws -> LookMatchResult {
        try analyzer.analyze(request, progress: progress)
    }
}

/// Groups a shoot into lighting scenes and adapts each scene's hero edit to the other photos.
/// Every decode is 512 px and only one is alive at a time.
final class LookMatchAnalyzer {
    static let analysisDimension: CGFloat = 512
    private lazy var context = CIContext(options: [.cacheIntermediates: false, .memoryTarget: 128])
    private var statistics: ImageStatistics { ImageStatistics(context: context) }

    /// What a quick look at each photo found: scene signals and a hero-suggestion score.
    private struct Survey {
        var signal: SceneSignal
        var rawInfo: RawInfo?
        var sharpness = 0.0
        var medianLuma = 0.5
    }

    /// Tone of a rendered photo in sRGB-encoded luma, and the color cast of its neutral
    /// evidence (log R/G and log B/G), nil when the photo has no credible neutral area.
    struct Measurement: Equatable {
        var median: Double
        var low: Double
        var high: Double
        var neutralRedGreen: Double?
        var neutralBlueGreen: Double?
    }

    private struct Hero {
        var photo: LookMatchPhoto
        var rawInfo: RawInfo?
        var measurement: Measurement
        /// Auto's warmth/tint fit for the hero's as-shot decode (non-RAW only).
        var neutralFit: (Double, Double)?
    }

    func analyze(_ request: LookMatchRequest,
                 progress: (Int, Int) -> Void = { _, _ in }) throws -> LookMatchResult {
        defer { context.clearCaches() }
        let adjustments = Dictionary(request.photos.map { ($0.id, $0.adjustments) }, uniquingKeysWith: { a, _ in a })
        let photos = Dictionary(request.photos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let total = request.photos.count * 2
        var done = 0

        var surveys: [UUID: Survey] = [:]
        for photo in request.photos {
            try Task.checkCancellation()
            surveys[photo.id] = autoreleasepool { survey(photo) }
            context.clearCaches()
            done += 1
            progress(done, total)
        }

        let groups = LookMatchScenes.group(request.photos.compactMap { surveys[$0.id]?.signal },
                                           thresholds: request.thresholds)
        let captureDates = surveys.compactMapValues(\.signal.captureDate)
        var scenes: [LookMatchScene] = []
        for (index, ids) in groups.enumerated() {
            var scene = LookMatchScene(index: index + 1, assetIDs: ids)
            if index > 0, let previous = groups[index - 1].last.flatMap({ surveys[$0]?.signal }),
               let first = ids.first.flatMap({ surveys[$0]?.signal }) {
                scene.splitReasons = LookMatchScenes.splitReasons(previous, first, thresholds: request.thresholds)
            }
            scene.heroID = LookMatchScenes.hero(in: ids, adjustments: adjustments,
                                                selectedID: request.selectedID, captureDates: captureDates)
            guard let heroID = scene.heroID, let heroPhoto = photos[heroID] else {
                scene.suggestedHeroID = suggestedHero(ids, surveys: surveys)
                done += ids.count
                progress(done, total)
                scenes.append(scene)
                continue
            }
            try Task.checkCancellation()
            let hero: Hero
            do {
                hero = try autoreleasepool { try measureHero(heroPhoto, rawInfo: surveys[heroID]?.rawInfo) }
            } catch {
                scene.unreadable = ids.filter { $0 != heroID }
                done += ids.count
                progress(done, total)
                scenes.append(scene)
                continue
            }
            context.clearCaches()
            done += 1
            for id in ids where id != heroID {
                try Task.checkCancellation()
                defer { done += 1; progress(done, total) }
                guard let photo = photos[id] else { continue }
                if LookMatchScenes.lookGroupCount(photo.adjustments) > 0 {
                    scene.alreadyEdited.append(id)
                    continue
                }
                do {
                    let proposal = try autoreleasepool {
                        try solve(photo, survey: surveys[id], hero: hero,
                                  heroSignal: surveys[heroID]?.signal, thresholds: request.thresholds)
                    }
                    scene.proposals.append(proposal)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    scene.unreadable.append(id)
                }
                context.clearCaches()
            }
            scenes.append(scene)
        }
        return LookMatchResult(scenes: scenes)
    }

    // MARK: - Survey

    /// The scene-grouping signals for one photo, for tuning diagnostics.
    func sceneSignal(for photo: LookMatchPhoto) -> SceneSignal {
        defer { clearCachesAfterSurvey() }
        return autoreleasepool { survey(photo).signal }
    }

    private func clearCachesAfterSurvey() { context.clearCaches() }

    private func survey(_ photo: LookMatchPhoto) -> Survey {
        let metadata = PhotoSourceLoader.metadata(of: photo.url)
        let rawInfo = PhotoSourceLoader.rawInfo(of: photo.url)
        var result = Survey(signal: SceneSignal(
            assetID: photo.id,
            captureDate: metadata?.captureDate,
            asShotMired: rawInfo.map { 1_000_000 / $0.asShotTemperature },
            exposureValue: ExposureMetadata.read(photo.url)?.exposureValue
        ), rawInfo: rawInfo)
        // RAW files use the camera's embedded preview here: enough for scene similarity and
        // sharpness, and about 50× faster than a RAW decode.
        guard let image = PhotoSourceLoader.loadThumbnail(photo.url, maxDimension: Self.analysisDimension),
              let cgImage = context.createCGImage(image, from: image.extent.integral,
                                                  format: .RGBA8, colorSpace: statistics.space)
        else { return result }
        result.signal.featurePrint = try? LookMatchScenes.featurePrint(of: cgImage)
        let still = CIImage(cgImage: cgImage)
        result.sharpness = sharpness(still)
        let lumas = statistics.pixels(still).map(\.luma).sorted()
        if !lumas.isEmpty { result.medianLuma = ImageStatistics.percentile(lumas, 0.5) }
        return result
    }

    /// Median gradient energy over a 4 × 4 grid of tiles of a 128 px grayscale copy.
    private func sharpness(_ image: CIImage) -> Double {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return 0 }
        let scale = 128 / max(extent.width, extent.height)
        let width = max(8, Int((extent.width * scale).rounded()))
        let height = max(8, Int((extent.height * scale).rounded()))
        let small = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(width) / extent.width, y: CGFloat(height) / extent.height))
        var buffer = [Float](repeating: 0, count: width * height)
        context.render(small, toBitmap: &buffer, rowBytes: width * 4,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .Lf,
                       colorSpace: CGColorSpace(name: CGColorSpace.linearGray))
        var tiles = [Double](repeating: 0, count: 16), counts = [Double](repeating: 0, count: 16)
        for y in 1 ..< height - 1 {
            for x in 1 ..< width - 1 {
                let i = y * width + x
                let gx = Double(buffer[i + 1] - buffer[i - 1]), gy = Double(buffer[i + width] - buffer[i - width])
                let tile = min(3, x * 4 / width) + min(3, y * 4 / height) * 4
                tiles[tile] += gx * gx + gy * gy
                counts[tile] += 1
            }
        }
        let energies = zip(tiles, counts).map { $0 / max(1, $1) }
        return ImageStatistics.median(energies)
    }

    /// The sharpest, best-exposed frame of a scene with no edited photo.
    private func suggestedHero(_ ids: [UUID], surveys: [UUID: Survey]) -> UUID? {
        let sharpest = ids.compactMap { surveys[$0]?.sharpness }.max() ?? 0
        func score(_ id: UUID) -> Double {
            guard let survey = surveys[id] else { return -1 }
            let sharp = sharpest > 0 ? survey.sharpness / sharpest : 0
            let centered = 1 - min(1, abs(survey.medianLuma - 0.46) / 0.46)
            return 0.6 * sharp + 0.4 * centered
        }
        return ids.enumerated().max { a, b in
            let x = score(a.element), y = score(b.element)
            return x != y ? x < y : a.offset > b.offset
        }?.element
    }

    // MARK: - Solve

    private func decode(_ url: URL, raw: RawSettings) throws -> CIImage {
        guard let loaded = PhotoSourceLoader.load(url, maxDimension: Self.analysisDimension, raw: raw),
              let raster = context.createCGImage(loaded, from: loaded.extent, format: .RGBAh,
                                                 colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        else { throw LookMatchError.unreadable }
        return CIImage(cgImage: raster)
    }

    func measure(_ image: CIImage) throws -> Measurement {
        let samples = statistics.pixels(image)
        let lumas = samples.map(\.luma).sorted()
        guard lumas.count >= 16 else { throw LookMatchError.unreadable }
        // Whole-frame color follows clothing and framing; only neutral areas show a cast.
        let neutral = ImageStatistics.neutralReference(samples)
        return Measurement(median: ImageStatistics.percentile(lumas, 0.5),
                           low: ImageStatistics.percentile(lumas, 0.02),
                           high: ImageStatistics.percentile(lumas, 0.98),
                           neutralRedGreen: neutral.map { log($0.r / $0.g) },
                           neutralBlueGreen: neutral.map { log($0.b / $0.g) })
    }

    private func measureHero(_ photo: LookMatchPhoto, rawInfo: RawInfo?) throws -> Hero {
        let source = try decode(photo.url, raw: photo.adjustments.raw)
        var neutralFit: (Double, Double)?
        if rawInfo == nil, let neutral = ImageStatistics.neutralReference(statistics.pixels(source)) {
            neutralFit = statistics.fitWhiteBalance(neutral)
        }
        let rendered = MediaColorRenderer.render(source, adjustments: photo.adjustments, includesGeometry: true)
        return Hero(photo: photo, rawInfo: rawInfo, measurement: try measure(rendered), neutralFit: neutralFit)
    }

    /// RAW white balance carried as the hero's offset from its own as-shot value: mired for
    /// temperature, additive for tint. A hero on as-shot WB gives a target on as-shot WB.
    static func carriedWhiteBalance(hero: RawSettings, heroAsShot: RawInfo, targetAsShot: RawInfo) -> (Double?, Double?) {
        guard hero.hasWhiteBalance else { return (nil, nil) }
        let heroTemperature = hero.temperature ?? heroAsShot.asShotTemperature
        let heroTint = hero.tint ?? heroAsShot.asShotTint
        let offset = 1_000_000 / heroTemperature - 1_000_000 / heroAsShot.asShotTemperature
        let mired = 1_000_000 / targetAsShot.asShotTemperature + offset
        let temperature = min(50000, max(2000, (1_000_000 / max(20, mired)).rounded()))
        let tint = min(150, max(-150, (targetAsShot.asShotTint + heroTint - heroAsShot.asShotTint).rounded()))
        return (temperature, tint)
    }

    private func solve(_ target: LookMatchPhoto, survey: Survey?, hero: Hero,
                       heroSignal: SceneSignal?, thresholds: LookMatchThresholds) throws -> LookMatchProposal {
        var proposal = hero.photo.adjustments.look(keepingGeometryOf: target.adjustments)
        let goal = hero.measurement

        // White balance. A white balance the photographer set on the target stays, as
        // `look(keepingGeometryOf:)` already kept it; otherwise carry the hero's offset.
        if !target.adjustments.raw.hasWhiteBalance,
           let heroInfo = hero.rawInfo, let targetInfo = survey?.rawInfo {
            let carried = Self.carriedWhiteBalance(hero: hero.photo.adjustments.raw,
                                                   heroAsShot: heroInfo, targetAsShot: targetInfo)
            proposal.raw.temperature = carried.0
            proposal.raw.tint = carried.1
        }
        let source = try decode(target.url, raw: proposal.raw)
        if survey?.rawInfo == nil, hero.rawInfo == nil, let heroFit = hero.neutralFit,
           let neutral = ImageStatistics.neutralReference(statistics.pixels(source)) {
            let fit = statistics.fitWhiteBalance(neutral)
            proposal.temperature = ImageStatistics.rounded(
                ImageStatistics.clamp(proposal.temperature + fit.0 - heroFit.0, -1, 1))
            proposal.tint = ImageStatistics.rounded(ImageStatistics.clamp(proposal.tint + fit.1 - heroFit.1, -1, 1))
        }

        // Exposure: match median luma in linear light, up to three passes.
        let base = hero.photo.adjustments
        let exposureRange = (base.exposure - thresholds.maximumExposureOffset) ... (base.exposure + thresholds.maximumExposureOffset)
        func rendered(_ adjustments: PhotoAdjustments) throws -> Measurement {
            try measure(MediaColorRenderer.render(source, adjustments: adjustments, includesGeometry: true))
        }
        var current = try rendered(proposal)
        for _ in 0 ..< 3 {
            try Task.checkCancellation()
            let change = log2(max(0.0001, ImageStatistics.linear(goal.median))
                / max(0.0001, ImageStatistics.linear(current.median)))
            guard abs(change) > 0.02 else { break }
            let exposure = ImageStatistics.clamp(proposal.exposure + change,
                                                 exposureRange.lowerBound, exposureRange.upperBound)
            guard exposure != proposal.exposure else { break }
            proposal.exposure = exposure
            current = try rendered(proposal)
        }

        // Highlights and shadows: a bounded nudge, kept only when it brings the ends closer.
        let highGap = goal.high - current.high, lowGap = goal.low - current.low
        if abs(highGap) > thresholds.percentileTolerance || abs(lowGap) > thresholds.percentileTolerance {
            var nudged = proposal
            let limit = thresholds.maximumToneNudge
            if abs(highGap) > thresholds.percentileTolerance {
                nudged.highlights = ImageStatistics.clamp(base.highlights + ImageStatistics.clamp(highGap * 2, -limit, limit), -1, 1)
            }
            if abs(lowGap) > thresholds.percentileTolerance {
                nudged.shadows = ImageStatistics.clamp(base.shadows + ImageStatistics.clamp(lowGap * 4, -limit, limit), -1, 1)
            }
            let after = try rendered(nudged)
            func spread(_ m: Measurement) -> Double { abs(goal.high - m.high) + abs(goal.low - m.low) }
            if spread(after) < spread(current) {
                proposal = nudged
                current = after
            }
        }
        proposal.exposure = ImageStatistics.rounded(proposal.exposure)
        proposal.highlights = ImageStatistics.rounded(proposal.highlights)
        proposal.shadows = ImageStatistics.rounded(proposal.shadows)

        let distance = LookMatchScenes.featureDistance(survey?.signal.featurePrint, heroSignal?.featurePrint)
        let confidence = Self.confidence(final: current, goal: goal, sceneDistance: distance, thresholds: thresholds)
        return LookMatchProposal(targetID: target.id, heroID: hero.photo.id, adjustments: proposal,
                                 confidence: confidence, isFlagged: confidence < thresholds.minimumConfidence)
    }

    /// 1 for a perfect match. Penalties: remaining median exposure error (full at 0.5 EV),
    /// 2nd/98th percentile error (full at 0.4), the difference between the hero's and the
    /// target's neutral-area color cast (full at 0.12 in log ratio; none when either has no
    /// neutral area), and visual distance from the hero (full at twice the scene threshold).
    /// Range and distance limits were widened after the 2026-10-18 family-portrait shoot, where
    /// framing changes alone flagged most frames under steady light.
    static func confidence(final: Measurement, goal: Measurement, sceneDistance: Double?,
                           thresholds: LookMatchThresholds) -> Double {
        let exposureError = abs(log2(max(0.0001, ImageStatistics.linear(goal.median))
            / max(0.0001, ImageStatistics.linear(final.median))))
        let rangeError = abs(goal.high - final.high) + abs(goal.low - final.low)
        var chromaError = 0.0
        if let a = goal.neutralRedGreen, let b = goal.neutralBlueGreen,
           let c = final.neutralRedGreen, let d = final.neutralBlueGreen {
            chromaError = hypot(a - c, b - d)
        }
        let scene = (sceneDistance ?? 0) / max(0.0001, thresholds.featurePrintDistance * 2)
        let penalty = 0.35 * min(1, exposureError / 0.5) + 0.15 * min(1, rangeError / 0.4)
            + 0.3 * min(1, chromaError / 0.12) + 0.2 * min(1, scene)
        return ImageStatistics.rounded(ImageStatistics.clamp(1 - penalty, 0, 1))
    }
}
