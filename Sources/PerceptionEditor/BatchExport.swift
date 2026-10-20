import Foundation

/// A file-level seam for deterministic queue and publication-boundary verification.
/// The application default uses one sequential PhotoRenderer for the entire queue.
typealias BatchPhotoExporter = @Sendable (BatchExportItem, URL, BatchExportRecipe, [URL]) async throws -> Void

struct BatchExportRecipe: Sendable, Codable, Equatable {
    /// Lossy quality for JPEG and HEIC; ignored by TIFF and PNG.
    var jpegQuality: Double = 0.92
    /// Nil preserves the finished photo's full pixel dimensions.
    var longEdgePixels: Int?
    var filenameSuffix = "_edited"
    var format: ExportFormat = .jpeg
    var sharpening: OutputSharpening = .none
    var metadata = ExportMetadataOptions()

    init(
        jpegQuality: Double = 0.92,
        longEdgePixels: Int? = nil,
        filenameSuffix: String = "_edited",
        format: ExportFormat = .jpeg,
        sharpening: OutputSharpening = .none,
        metadata: ExportMetadataOptions = ExportMetadataOptions()
    ) {
        self.jpegQuality = jpegQuality
        self.longEdgePixels = longEdgePixels
        self.filenameSuffix = filenameSuffix
        self.format = format
        self.sharpening = sharpening
        self.metadata = metadata
    }

    /// Fields added after the first recipes decode with defaults, so saved recipes keep opening.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jpegQuality = try container.decodeIfPresent(Double.self, forKey: .jpegQuality) ?? 0.92
        longEdgePixels = try container.decodeIfPresent(Int.self, forKey: .longEdgePixels)
        filenameSuffix = try container.decodeIfPresent(String.self, forKey: .filenameSuffix) ?? "_edited"
        format = try container.decodeIfPresent(ExportFormat.self, forKey: .format) ?? .jpeg
        sharpening = try container.decodeIfPresent(OutputSharpening.self, forKey: .sharpening) ?? .none
        metadata = try container.decodeIfPresent(ExportMetadataOptions.self, forKey: .metadata) ?? ExportMetadataOptions()
    }

    func validate() throws {
        guard jpegQuality.isFinite, (0.5...1).contains(jpegQuality) else {
            throw BatchExportError.invalidQuality
        }
        if let longEdgePixels, !(1...20_000).contains(longEdgePixels) {
            throw BatchExportError.invalidLongEdge
        }
        guard metadata.isValid else { throw BatchExportError.invalidMetadata }
        guard filenameSuffix.utf8.count <= 40,
              filenameSuffix.utf8.allSatisfy({ byte in
                  (65...90).contains(byte) || (97...122).contains(byte) ||
                      (48...57).contains(byte) || byte == 45 || byte == 95
              }) else {
            throw BatchExportError.invalidSuffix
        }
    }
}

enum BatchExportError: LocalizedError {
    case invalidQuality
    case invalidLongEdge
    case invalidSuffix
    case invalidMetadata
    case noPhotosSelected
    case alreadyExporting
    case tooManyNameCollisions

    var errorDescription: String? {
        switch self {
        case .invalidQuality: "Choose JPEG quality between 50% and 100%."
        case .invalidLongEdge: "Choose a long edge between 1 and 20,000 pixels."
        case .invalidSuffix: "Use up to 40 letters, numbers, underscores, or hyphens in the filename suffix."
        case .invalidMetadata: "Copyright and creator must be one line, up to 200 and 100 characters."
        case .noPhotosSelected: "Select at least one photo to export."
        case .alreadyExporting: "Wait for the current export to finish or stop it first."
        case .tooManyNameCollisions: "Could not find an unused output filename."
        }
    }
}

struct BatchExportItem: Sendable {
    let id: UUID
    let source: URL
    let adjustments: PhotoAdjustments

    var filename: String { source.lastPathComponent }
}

struct BatchExportFileResult: Identifiable {
    let id: UUID
    let sourceName: String
    let output: URL?
    let error: String?

    var succeeded: Bool { output != nil }
}

struct BatchExportState {
    var total = 0
    var completed = 0
    var currentFilename: String?
    var results: [BatchExportFileResult] = []
    var wasCancelled = false
}

/// Plans names immediately before each file. Existing deliverables and names already
/// assigned in this run get numbered suffixes; publication still refuses a late collision.
enum BatchExportPlanner {
    static func destination(
        for item: BatchExportItem,
        in folder: URL,
        suffix: String,
        fileExtension: String = "jpg",
        reserved: inout Set<String>,
        protecting originals: [URL]
    ) throws -> URL {
        let stem = item.source.deletingPathExtension().lastPathComponent
        let base = (stem.isEmpty ? "Photo" : stem) + suffix
        for number in 1...10_000 {
            let tail = number == 1 ? "" : "-\(number)"
            let candidate = folder.appendingPathComponent("\(base)\(tail).\(fileExtension)")
            let path = candidate.standardizedFileURL.resolvingSymlinksInPath().path
            guard !reserved.contains(path), !FileManager.default.fileExists(atPath: path) else { continue }
            do {
                try ExportFileSafety.validate(candidate, protecting: originals)
            } catch ExportFileError.protectedOriginal {
                continue
            }
            reserved.insert(path)
            return candidate
        }
        throw BatchExportError.tooManyNameCollisions
    }
}
