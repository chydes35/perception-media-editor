import CoreImage
import CoreVideo
import Foundation
@preconcurrency import Vision

/// Recover small detected people whom full-frame instance segmentation misses.
/// Crops can contain nearby people, so they remain explicitly named area selections.
enum SubjectGroupRecovery {
    struct Result {
        var candidates: [SubjectCandidate] = []
        var labels: SubjectLabelMap?
    }

    static func analyze(image: CIImage, candidates: [SubjectCandidate], labels: [SubjectLabelMap?]) throws -> Result {
        try Task.checkCancellation()
        let detection = VNDetectHumanRectanglesRequest()
        detection.upperBodyOnly = true
        do { try VNImageRequestHandler(ciImage: image, options: [:]).perform([detection]) }
        catch { try Task.checkCancellation(); return Result() } // Preserve the original selections.
        try Task.checkCancellation()
        let context = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: NSNull(),
                                         .outputColorSpace: NSNull(), .memoryTarget: 128])
        defer { context.clearCaches() }
        var excluded = CIImage(color: .black).cropped(to: image.extent)
        if !candidates.isEmpty {
            excluded = CIImage(data: try SubjectAnalyzer.unionPNG(candidates.map(\.png)), options: [.colorSpace: NSNull()]) ?? excluded
        }
        // Instance labels can claim a small person even when the offered scaled mask
        // omits them. Judge actual editable coverage rather than that coarse label.
        func alreadyOffered(at point: NormalizedPoint) -> Bool {
            var pixel: UInt8 = 0
            context.render(excluded, toBitmap: &pixel, rowBytes: 1,
                           bounds: CGRect(x: point.x * image.extent.width,
                                          y: (1 - point.y) * image.extent.height, width: 1, height: 1),
                           format: .L8, colorSpace: nil)
            return pixel >= 128
        }
        let missing = (detection.results ?? []).filter { human in
            let box = human.boundingBox
            let center = NormalizedPoint(x: box.midX, y: 1 - box.midY)
            return human.confidence >= 0.6 && box.width * box.height < 0.03 &&
                !alreadyOffered(at: center)
        }.sorted { $0.confidence > $1.confidence }.prefix(3)
        guard !missing.isEmpty else { return Result() }
        let width = labels.compactMap { $0?.width }.first ?? 512
        let height = labels.compactMap { $0?.height }.first ?? max(1, Int(512 * image.extent.height / image.extent.width))
        var picked = [UInt8](repeating: 0, count: width * height)
        var result = Result()
        for human in missing {
            try Task.checkCancellation()
            let box = human.boundingBox
            let rect = CGRect(x: image.extent.minX + (box.minX - box.width * 0.5) * image.extent.width,
                              y: image.extent.minY + (box.minY - box.height * 2.5) * image.extent.height,
                              width: box.width * 2 * image.extent.width,
                              height: box.height * 4 * image.extent.height).integral.intersection(image.extent)
            guard rect.width > 0, rect.height > 0 else { continue }
            let crop = image.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = .accurate
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            do { try VNImageRequestHandler(ciImage: crop, options: [:]).perform([request]) }
            catch { try Task.checkCancellation(); continue }
            try Task.checkCancellation()
            guard let buffer = request.results?.first?.pixelBuffer else { continue }
            let raw = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
            let positioned = raw.transformed(by: CGAffineTransform(scaleX: rect.width / raw.extent.width,
                                                                   y: rect.height / raw.extent.height))
                .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
                .composited(over: CIImage(color: .black).cropped(to: image.extent))
            let recovered = positioned.applyingFilter("CIMinimumCompositing", parameters: [
                kCIInputBackgroundImageKey: excluded.applyingFilter("CIColorInvert")
            ]).cropped(to: image.extent)
            // Top-first labels preserve the same source-coordinate picking contract.
            let grid = recovered.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / image.extent.width,
                                                                    y: CGFloat(height) / image.extent.height))
            var bytes = [UInt8](repeating: 0, count: width * height)
            context.render(grid, toBitmap: &bytes, rowBytes: width,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .L8, colorSpace: nil)
            let localID = UInt8(result.candidates.count + 1)
            let count = bytes.filter { $0 >= 128 }.count
            guard count >= 8 else { continue }
            for y in 0..<height {
                for x in 0..<width where bytes[y * width + x] >= 128 {
                    picked[y * width + x] = localID
                }
            }
            let png = try SubjectAnalyzer.encodeMask(recovered)
            result.candidates.append(SubjectCandidate(id: 512 + Int(localID), kind: .group, png: png, pixelCount: count))
            excluded = CIImage(data: try SubjectAnalyzer.unionPNG([try SubjectAnalyzer.encodeMask(excluded), png]),
                               options: [.colorSpace: NSNull()]) ?? excluded
            context.clearCaches()
        }
        if !result.candidates.isEmpty { result.labels = SubjectLabelMap(data: Data(picked), width: width, height: height) }
        return result
    }
}
