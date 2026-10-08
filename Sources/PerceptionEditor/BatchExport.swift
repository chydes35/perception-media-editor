import Foundation

struct BatchExportRecipe: Sendable {
    var jpegQuality: Double = 0.92
    /// Nil preserves the finished photo's full pixel dimensions.
    var longEdgePixels: Int?
    var filenameSuffix = "_edited"

    func validate() throws {
        guard jpegQuality.isFinite, (0.5...1).contains(jpegQuality) else {
            throw BatchExportError.invalidQuality
        }
        if let longEdgePixels, !(1...20_000).contains(longEdgePixels) {
            throw BatchExportError.invalidLongEdge
        }
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
    case noPhotosSelected
    case alreadyExporting
    case tooManyNameCollisions

    var errorDescription: String? {
        switch self {
        case .invalidQuality: "Choose JPEG quality between 50% and 100%."
        case .invalidLongEdge: "Choose a long edge between 1 and 20,000 pixels."
        case .invalidSuffix: "Use up to 40 letters, numbers, underscores, or hyphens in the filename suffix."
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
        reserved: inout Set<String>,
        protecting originals: [URL]
    ) throws -> URL {
        let stem = item.source.deletingPathExtension().lastPathComponent
        let base = (stem.isEmpty ? "Photo" : stem) + suffix
        for number in 1...10_000 {
            let tail = number == 1 ? "" : "-\(number)"
            let candidate = folder.appendingPathComponent("\(base)\(tail).jpg")
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
