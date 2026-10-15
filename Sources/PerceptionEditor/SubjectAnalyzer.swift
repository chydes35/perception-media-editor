import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
@preconcurrency import Vision

struct SubjectCandidate: Identifiable, Sendable {
    enum Kind: Sendable { case person, object, group }
    let id: Int
    let kind: Kind
    let png: Data
    let pixelCount: Int

    var name: String {
        switch kind {
        case .person: "Person \(id)"
        case .object: "Object \(id - 256)"
        case .group: "People in area \(id - 512)"
        }
    }
}

struct SubjectLabelMap: Sendable {
    let data: Data
    let width: Int
    let height: Int

    func label(at point: NormalizedPoint) -> Int? {
        guard (0 ... 1).contains(point.x), (0 ... 1).contains(point.y),
              width > 0, height > 0 else { return nil }
        let x = min(width - 1, Int(point.x * Double(width)))
        let y = min(height - 1, Int(point.y * Double(height)))
        let value = Int(data[y * width + x])
        return value == 0 ? nil : value
    }
}

struct SubjectAnalysis: Sendable {
    let candidates: [SubjectCandidate]
    let allSubjectsPNG: Data
    /// Vision's low-resolution labels, copied into tightly packed top-left rows.
    let personLabels: SubjectLabelMap?
    let foregroundLabels: SubjectLabelMap?
    var supplementalLabels: SubjectLabelMap? = nil

    func candidate(at point: NormalizedPoint) -> SubjectCandidate? {
        if let id = supplementalLabels?.label(at: point) {
            return candidates.first { $0.id == id + 512 && $0.kind == .group }
        }
        if let id = personLabels?.label(at: point),
           let person = candidates.first(where: { $0.id == id && $0.kind == .person }) {
            return person
        }
        if let id = foregroundLabels?.label(at: point) {
            if let object = candidates.first(where: { $0.id == id + 256 && $0.kind == .object }) { return object }
        }
        return nil
    }
}

enum SubjectSelectionError: LocalizedError {
    case noPhoto, noSubjects, invalidMask

    var errorDescription: String? {
        switch self {
        case .noPhoto: "The photo could not be decoded for subject selection."
        case .noSubjects: "No foreground subjects were found in this photo."
        case .invalidMask: "The subject mask could not be prepared."
        }
    }
}

/// Runs Apple's foreground instance segmentation on an oriented 3072-pixel source. The
/// high-resolution soft masks are stored as grayscale PNGs for reproducible project edits.
enum SubjectAnalyzer {
    static func analyze(url: URL) throws -> SubjectAnalysis {
        guard let image = PhotoSourceLoader.load(url, maxDimension: 3072) else {
            throw SubjectSelectionError.noPhoto
        }
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        let foregroundRequest = VNGenerateForegroundInstanceMaskRequest()
        let personRequest = VNGeneratePersonInstanceMaskRequest()
        try handler.perform([foregroundRequest])
        // Person instances can separate people whom the general foreground model groups.
        // A person-model failure still leaves the general foreground result usable.
        try? handler.perform([personRequest])
        let foreground = foregroundRequest.results?.first
        let people = personRequest.results?.first
        guard foreground?.allInstances.isEmpty == false || people?.allInstances.isEmpty == false
        else { throw SubjectSelectionError.noSubjects }

        let personLabels = try people.map { try copyLabels($0.instanceMask) }
        let foregroundLabels = try foreground.map { try copyLabels($0.instanceMask) }
        var candidates: [SubjectCandidate] = []
        if let people, let personLabels {
            let counts = pixelCounts(personLabels)
            for id in people.allInstances where id <= Int(UInt8.max) {
                let png = try encodeMask(people.generateScaledMaskForImage(
                    forInstances: IndexSet(integer: id), from: handler
                ))
                candidates.append(SubjectCandidate(
                    id: id, kind: .person, png: png,
                    pixelCount: counts[UInt8(id)] ?? 0
                ))
            }
        }
        if let foreground, let foregroundLabels {
            let counts = pixelCounts(foregroundLabels)
            for id in foreground.allInstances where id <= Int(UInt8.max) {
                let coverage = personCoverage(
                    foregroundID: UInt8(id), foreground: foregroundLabels, people: personLabels
                )
                // Suppress a general-foreground instance that is mostly the same people.
                if coverage > 0.6 { continue }
                let png = try encodeMask(foreground.generateScaledMaskForImage(
                    forInstances: IndexSet(integer: id), from: handler
                ))
                candidates.append(SubjectCandidate(
                    id: id + 256, kind: .object, png: png,
                    pixelCount: counts[UInt8(id)] ?? 0
                ))
            }
        }
        let recovered = try SubjectGroupRecovery.analyze(image: image, candidates: candidates,
                                                        labels: [personLabels, foregroundLabels])
        candidates.append(contentsOf: recovered.candidates)
        candidates = refineEdges(of: candidates, image: image)
        candidates.sort { $0.pixelCount > $1.pixelCount }
        guard !candidates.isEmpty else { throw SubjectSelectionError.noSubjects }
        // The overview must contain exactly the candidates offered to the user, including
        // people missed by the foreground model, without reintroducing suppressed groups.
        let allSubjectsPNG = try unionPNG(candidates.map(\.png))
        return SubjectAnalysis(
            candidates: candidates, allSubjectsPNG: allSubjectsPNG,
            personLabels: personLabels, foregroundLabels: foregroundLabels,
            supplementalLabels: recovered.labels
        )
    }

    /// Fits each candidate's edge to the photo (fine hair, spill). Falls back to the model's mask
    /// when the source cannot be reduced; pixel counts and identities are unchanged.
    private static func refineEdges(of candidates: [SubjectCandidate], image: CIImage) -> [SubjectCandidate] {
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])
        guard let source = SubjectEdgeMatting.Source(image: image, context: context) else { return candidates }
        return candidates.map { candidate in
            SubjectCandidate(id: candidate.id, kind: candidate.kind,
                             png: SubjectEdgeMatting.refinePNG(candidate.png, source: source, context: context),
                             pixelCount: candidate.pixelCount)
        }
    }

    private static func pixelCounts(_ map: SubjectLabelMap) -> [UInt8: Int] {
        map.data.reduce(into: [UInt8: Int]()) { counts, label in
            if label != 0 { counts[label, default: 0] += 1 }
        }
    }

    private static func personCoverage(
        foregroundID: UInt8, foreground: SubjectLabelMap, people: SubjectLabelMap?
    ) -> Double {
        guard let people else { return 0 }
        var total = 0, covered = 0
        for y in 0 ..< foreground.height {
            for x in 0 ..< foreground.width where foreground.data[y * foreground.width + x] == foregroundID {
                total += 1
                let point = NormalizedPoint(
                    x: (Double(x) + 0.5) / Double(foreground.width),
                    y: (Double(y) + 0.5) / Double(foreground.height)
                )
                if people.label(at: point) != nil { covered += 1 }
            }
        }
        return total == 0 ? 0 : Double(covered) / Double(total)
    }

    private static func copyLabels(_ buffer: CVPixelBuffer) throws -> SubjectLabelMap {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8 else {
            throw SubjectSelectionError.invalidMask
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw SubjectSelectionError.invalidMask }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var result = Data(count: width * height)
        result.withUnsafeMutableBytes { output in
            guard let bytes = output.baseAddress else { return }
            for row in 0 ..< height {
                bytes.advanced(by: row * width).copyMemory(
                    from: base.advanced(by: row * rowBytes), byteCount: width
                )
            }
        }
        return SubjectLabelMap(data: result, width: width, height: height)
    }

    private static func encodeMask(_ buffer: CVPixelBuffer) throws -> Data {
        let image = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
        return try encodeMask(image)
    }

    /// Materialize each merge so memory stays bounded to the running union and next mask.
    static func unionPNG(_ masks: [Data]) throws -> Data {
        guard let first = masks.first,
              var union = CIImage(data: first, options: [.colorSpace: NSNull()])
        else { throw SubjectSelectionError.invalidMask }
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        for png in masks.dropFirst() {
            guard let next = CIImage(data: png, options: [.colorSpace: NSNull()]),
                  next.extent == union.extent else { throw SubjectSelectionError.invalidMask }
            let merged = union.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: next])
            guard let raster = context.createCGImage(
                merged, from: union.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray()
            ) else { throw SubjectSelectionError.invalidMask }
            union = CIImage(cgImage: raster, options: [.colorSpace: NSNull()])
        }
        return try encodeMask(union)
    }

    static func encodeMask(_ image: CIImage) throws -> Data {
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        guard let grayscale = context.createCGImage(
            image, from: image.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray()
        ) else { throw SubjectSelectionError.invalidMask }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil
        ) else { throw SubjectSelectionError.invalidMask }
        CGImageDestinationAddImage(destination, grayscale, nil)
        guard CGImageDestinationFinalize(destination) else { throw SubjectSelectionError.invalidMask }
        return output as Data
    }
}

/// Kept off PhotoRenderer's actor so segmentation cannot hold up editing previews.
actor SubjectAnalysisService {
    func analyze(url: URL) throws -> SubjectAnalysis {
        try SubjectAnalyzer.analyze(url: url)
    }
}
