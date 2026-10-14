import Darwin
import Foundation

enum ExportFileError: LocalizedError {
    case protectedOriginal
    case destinationExists

    var errorDescription: String? {
        switch self {
        case .protectedOriginal:
            "Choose a different export location. Original media cannot be overwritten."
        case .destinationExists:
            "An output with this name already exists. No file was replaced."
        }
    }
}

/// Enforces the original-media boundary for every export caller, including path aliases.
enum ExportFileSafety {
    static func validate(_ destination: URL, protecting originals: [URL]) throws {
        let resolved = destination.standardizedFileURL.resolvingSymlinksInPath()
        let identity = fileIdentity(resolved)
        for original in originals {
            let source = original.standardizedFileURL.resolvingSymlinksInPath()
            if source == resolved || (identity != nil && identity == fileIdentity(source)) {
                throw ExportFileError.protectedOriginal
            }
        }
    }

    /// A failed render leaves an existing deliverable intact. The final rename is on the
    /// same filesystem and replaces only the completed output, never a partially written file.
    static func writeAtomically(
        to destination: URL,
        protecting originals: [URL],
        replaceExisting: Bool = true,
        write: (URL) throws -> Void
    ) throws {
        try validate(destination, protecting: originals)
        let resolved = destination.standardizedFileURL.resolvingSymlinksInPath()
        let temporary = resolved.deletingLastPathComponent()
            .appendingPathComponent(".pme-export-\(UUID().uuidString).\(resolved.pathExtension)")
        defer { try? FileManager.default.removeItem(at: temporary) }

        try Task.checkCancellation()
        try write(temporary)
        try Task.checkCancellation()
        // Recheck after rendering in case a destination was relinked while it was running.
        try validate(destination, protecting: originals)
        try validate(resolved, protecting: originals)
        // Batch delivery creates a new hard link atomically. If a file appears during
        // rendering, EEXIST leaves it untouched. The temporary link is then removed.
        let published = replaceExisting
            ? rename(temporary.path, resolved.path)
            : link(temporary.path, resolved.path)
        guard published == 0 else {
            if !replaceExisting && errno == EEXIST { throw ExportFileError.destinationExists }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                NSFilePathErrorKey: resolved.path
            ])
        }
    }

    private struct Identity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    /// Device + inode also catches hard links and case aliases on case-insensitive volumes.
    private static func fileIdentity(_ url: URL) -> Identity? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber
        else { return nil }
        return Identity(device: device.uint64Value, inode: inode.uint64Value)
    }
}
