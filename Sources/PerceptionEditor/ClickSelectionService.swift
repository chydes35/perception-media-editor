import CoreImage
import Foundation

/// One proposed selection: the mask PNG, the model's own score, and the share of the photo it covers.
struct ClickMask: Equatable, Sendable {
    var png: Data
    var score: Float
    var coverage: Double

    /// The mask to show first. Among masks that stay under a third of the frame (a click that selects the
    /// lawn is rarely wanted) the model's most confident one; if every mask is larger, the smallest.
    static func defaultIndex(in masks: [ClickMask]) -> Int {
        let modest = masks.indices.filter { masks[$0].coverage <= 1.0 / 3 }
        if let best = modest.max(by: { masks[$0].score < masks[$1].score }) { return best }
        return masks.indices.min { masks[$0].coverage < masks[$1].coverage } ?? 0
    }
}

/// Runs click-to-select off the main actor: analyzes a photo once, answers click sets with mask PNGs, and
/// lets the models go after a quiet period (the 8 GB target Mac cannot keep them resident for long).
actor ClickSelectionService {
    /// The long side of the photo copy the model sees and of the masks it returns.
    static let workingDimension: CGFloat = 1536
    static let idleSeconds = 120.0

    private let segmenter: any PromptableSegmenter
    private let idleSeconds: Double
    private var preparedPhotoID: UUID?
    private var maskWidth = 0
    private var maskHeight = 0
    private var edgeSource: SubjectEdgeMatting.Source?
    private var idleTask: Task<Void, Never>?

    init(segmenter: any PromptableSegmenter = SAM2Segmenter(), idleSeconds: Double = ClickSelectionService.idleSeconds) {
        self.segmenter = segmenter
        self.idleSeconds = idleSeconds
    }

    var isLoaded: Bool { preparedPhotoID != nil }

    func prepare(url: URL, photoID: UUID) async throws {
        idleTask?.cancel()
        defer { scheduleUnload() }
        if preparedPhotoID == photoID { return }
        guard var image = PhotoSourceLoader.load(url, maxDimension: Self.workingDimension) else {
            throw SegmentationError.noPhoto
        }
        if PhotoSourceLoader.hasHeadroom(url) { image = HighlightRolloff.apply(image, white: HighlightRolloff.baseWhite) }
        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0,
              let cgImage = CIContext().createCGImage(image, from: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        else { throw SegmentationError.noPhoto }
        try Task.checkCancellation()
        try await segmenter.prepare(photoID: photoID, image: cgImage)
        edgeSource = SubjectEdgeMatting.Source(image: image, context: CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()]))
        preparedPhotoID = photoID
        maskWidth = cgImage.width
        maskHeight = cgImage.height
    }

    /// Masks for the clicks, smallest region first (part, object, whole).
    func masks(photoID: UUID, points: [SegmentationPoint]) async throws -> [ClickMask] {
        idleTask?.cancel()
        defer { scheduleUnload() }
        guard preparedPhotoID == photoID else { throw SegmentationError.notPrepared }
        let candidates = try await segmenter.candidates(photoID: photoID, points: points)
        let (width, height) = (maskWidth, maskHeight)
        let masks = candidates.compactMap { candidate -> ClickMask? in
            let pixels = SegmentationPostprocessing.maskPixels(candidate, width: width, height: height)
            guard let png = SegmentationPostprocessing.png(pixels: pixels, width: width, height: height) else { return nil }
            return ClickMask(png: png, score: candidate.score,
                             coverage: Double(candidate.insideCount) / Double(candidate.logits.count))
        }
        guard !masks.isEmpty else { throw SegmentationError.invalidOutput }
        return masks
    }

    /// The accepted mask with its edge fitted to the photo (fine hair, spill), or unchanged if that is not possible.
    func refinedPNG(photoID: UUID, png: Data) -> Data {
        idleTask?.cancel()
        defer { scheduleUnload() }
        guard preparedPhotoID == photoID, let edgeSource else { return png }
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])
        return SubjectEdgeMatting.refinePNG(png, source: edgeSource, context: context)
    }

    func unload() async {
        idleTask?.cancel()
        preparedPhotoID = nil
        edgeSource = nil
        await segmenter.unload()
    }

    private func scheduleUnload() {
        idleTask?.cancel()
        let seconds = idleSeconds
        idleTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            await self?.unload()
        }
    }
}
