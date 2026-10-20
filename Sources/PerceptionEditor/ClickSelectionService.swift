import CoreImage
import Foundation

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
        preparedPhotoID = photoID
        maskWidth = cgImage.width
        maskHeight = cgImage.height
    }

    /// Mask PNGs for the clicks, smallest region first (part, object, whole).
    func maskPNGs(photoID: UUID, points: [SegmentationPoint]) async throws -> [Data] {
        idleTask?.cancel()
        defer { scheduleUnload() }
        guard preparedPhotoID == photoID else { throw SegmentationError.notPrepared }
        let candidates = try await segmenter.candidates(photoID: photoID, points: points)
        let (width, height) = (maskWidth, maskHeight)
        let pngs = candidates.compactMap { candidate in
            SegmentationPostprocessing.png(
                pixels: SegmentationPostprocessing.maskPixels(candidate, width: width, height: height),
                width: width, height: height)
        }
        guard !pngs.isEmpty else { throw SegmentationError.invalidOutput }
        return pngs
    }

    func unload() async {
        idleTask?.cancel()
        preparedPhotoID = nil
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
