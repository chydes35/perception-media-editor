import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// A media file found on a card or folder that is about to be copied into a shoot.
struct SourceFile: Sendable, Equatable {
    var url: URL
    var kind: MediaKind
    var size: Int64
}

struct IngestedFile: Sendable, Equatable {
    var sourceURL: URL
    var destinationURL: URL
    var kind: MediaKind
    var metadata: PhotoMetadata?
    /// True when an identical file was already in the shoot, so nothing was copied.
    var alreadyPresent: Bool
}

struct IngestFailure: Sendable, Equatable {
    var filename: String
    var reason: String
}

enum BackupOutcome: Sendable, Equatable {
    case notRequested
    case unavailable(String)
    case completed(copied: Int, alreadyPresent: Int)
    case partial(copied: Int, failed: Int)
}

struct IngestProgress: Sendable, Equatable {
    enum Phase: Sendable, Equatable { case copying, backingUp }

    var phase: Phase
    var completedFiles: Int
    var totalFiles: Int
    var completedBytes: Int64
    var totalBytes: Int64
    var currentFilename: String

    var fraction: Double {
        totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : 0
    }
}

struct IngestResult: Sendable {
    var files: [IngestedFile] = []
    var copiedCount = 0
    var alreadyPresentCount = 0
    var failures: [IngestFailure] = []
    var backup = BackupOutcome.notRequested
    var wasCancelled = false
}

enum IngestError: LocalizedError {
    case notEnoughSpace(needed: Int64, available: Int64, volume: String)
    case verificationFailed(String)
    case couldNotCreateFile(String)

    var errorDescription: String? {
        switch self {
        case .notEnoughSpace(let needed, let available, let volume):
            let format = ByteCountFormatter()
            return "Not enough space on \(volume): \(format.string(fromByteCount: needed)) needed, "
                + "\(format.string(fromByteCount: available)) available."
        case .verificationFailed(let name):
            return "The copy of \(name) did not match the original, so it was discarded."
        case .couldNotCreateFile(let name):
            return "Could not create \(name)."
        }
    }
}

/// Copies media from a card or folder into a shoot, verifying every byte.
///
/// The source is only ever read. Each file is copied to a `.partial` name while a SHA-256 of the
/// source stream is computed, flushed to disk, read back without the file cache, compared, and
/// only then renamed into place, so an interrupted import never leaves a half-written original
/// under a real filename. Re-importing the same card skips identical files, and a different
/// file with a colliding name gets a numeric suffix rather than overwriting anything.
enum IngestService {
    static let chunkSize = 4 * 1024 * 1024
    static let partialSuffix = ".partial"

    // MARK: - Scanning

    static func kind(for url: URL) -> MediaKind? {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return nil }
        if type.conforms(to: .rawImage) || type.conforms(to: .image) { return .photo }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .audio) { return .audio }
        return nil
    }

    /// Photos, video, and audio under `root`, in path order. Hidden files (including the
    /// `._name` companions macOS writes on non-Mac volumes) are skipped.
    static func scan(_ root: URL) -> [SourceFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var files: [SourceFile] = []
        for case let url as URL in enumerator {
            guard
                !url.lastPathComponent.hasPrefix("."),
                let values = try? url.resourceValues(forKeys: Set(keys)),
                values.isRegularFile == true,
                let kind = kind(for: url)
            else { continue }
            files.append(SourceFile(url: url, kind: kind, size: Int64(values.fileSize ?? 0)))
        }
        return files.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
    }

    /// Mounted volumes that look like camera cards (they contain a DCIM folder).
    static func detectedCards() -> [URL] {
        let volumes = URL(fileURLWithPath: "/Volumes")
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: volumes,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("DCIM").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - Ingest

    /// Copies `files` into `originals`, then (optionally) into `backupOriginals`.
    /// Cancelling the calling task stops after the current file and returns what finished.
    static func ingest(
        files: [SourceFile],
        originals: URL,
        backupOriginals: URL?,
        onFile: @escaping @Sendable (IngestedFile) -> Void = { _ in },
        progress: @escaping @Sendable (IngestProgress) -> Void = { _ in }
    ) throws -> IngestResult {
        var result = IngestResult()
        let totalBytes = files.reduce(Int64(0)) { $0 + $1.size }

        try prepareDirectory(originals, requiring: totalBytes)
        removeStalePartials(in: originals)

        var digests: [URL: SHA256.Digest] = [:]
        var completedBytes: Int64 = 0

        for (index, file) in files.enumerated() {
            if Task.isCancelled {
                result.wasCancelled = true
                break
            }
            let send = { (bytes: Int64) in
                progress(IngestProgress(
                    phase: .copying,
                    completedFiles: index,
                    totalFiles: files.count,
                    completedBytes: completedBytes + bytes,
                    totalBytes: totalBytes,
                    currentFilename: file.url.lastPathComponent
                ))
            }
            send(0)

            do {
                let outcome = try place(file, in: originals, onBytes: send)
                if let digest = outcome.digest { digests[outcome.destination] = digest }
                let ingested = IngestedFile(
                    sourceURL: file.url,
                    destinationURL: outcome.destination,
                    kind: file.kind,
                    metadata: file.kind == .photo ? PhotoSourceLoader.metadata(of: outcome.destination) : nil,
                    alreadyPresent: outcome.alreadyPresent
                )
                result.files.append(ingested)
                if outcome.alreadyPresent { result.alreadyPresentCount += 1 } else { result.copiedCount += 1 }
                onFile(ingested)
            } catch is CancellationError {
                result.wasCancelled = true
                break
            } catch {
                result.failures.append(IngestFailure(
                    filename: file.url.lastPathComponent,
                    reason: error.localizedDescription
                ))
            }
            completedBytes += file.size
        }

        if let backupOriginals, !result.files.isEmpty, !result.wasCancelled {
            result.backup = backUp(
                result.files,
                digests: digests,
                to: backupOriginals,
                progress: progress
            )
        } else if backupOriginals != nil {
            result.backup = .notRequested
        }
        return result
    }

    // MARK: - Placing one file

    private struct Placement {
        var destination: URL
        /// Nil when an existing file was recognised by size and timestamp without hashing.
        var digest: SHA256.Digest?
        var alreadyPresent: Bool
    }

    /// Copies `file` into `directory` under a name that does not collide with different content.
    /// The source is hashed while it is copied, so the card is read once. `knownDigest` (used
    /// for backups, where the primary copy was already verified) is checked against that stream.
    private static func place(
        _ file: SourceFile,
        in directory: URL,
        knownDigest: SHA256.Digest? = nil,
        onBytes: (Int64) -> Void
    ) throws -> Placement {
        let stem = file.url.deletingPathExtension().lastPathComponent
        let ext = file.url.pathExtension
        var sourceDigest = knownDigest

        for attempt in 0 ..< 1000 {
            let name = attempt == 0 ? file.url.lastPathComponent : "\(stem)-\(attempt)" + (ext.isEmpty ? "" : ".\(ext)")
            let candidate = directory.appendingPathComponent(name)

            if FileManager.default.fileExists(atPath: candidate.path) {
                let existingSize = (try? candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
                if existingSize == file.size {
                    // Copies keep the original's timestamp, so the same name, size, and timestamp
                    // means an earlier import of this file: skip it without reading it all again.
                    if sameModificationTime(file.url, candidate) {
                        onBytes(file.size)
                        return Placement(destination: candidate, digest: sourceDigest, alreadyPresent: true)
                    }
                    // Same name and size but a different timestamp: compare the contents.
                    let digest = try sourceDigest ?? sha256(of: file.url)
                    sourceDigest = digest
                    if (try? sha256(of: candidate)) == digest {
                        onBytes(file.size)
                        return Placement(destination: candidate, digest: digest, alreadyPresent: true)
                    }
                }
                continue
            }

            let digest = try copyVerified(from: file.url, to: candidate, expected: sourceDigest, onBytes: onBytes)
            return Placement(destination: candidate, digest: digest, alreadyPresent: false)
        }
        throw IngestError.couldNotCreateFile(file.url.lastPathComponent)
    }

    /// Streams `source` to `destination.partial` while hashing it, checks that hash against
    /// `expected` when given, verifies the written file by reading it back from disk, then
    /// renames it into place. Returns the source's SHA-256.
    @discardableResult
    static func copyVerified(
        from source: URL,
        to destination: URL,
        expected: SHA256.Digest? = nil,
        onBytes: (Int64) -> Void
    ) throws -> SHA256.Digest {
        let partial = URL(fileURLWithPath: destination.path + partialSuffix)
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: partial)
        guard fileManager.createFile(atPath: partial.path, contents: nil) else {
            throw IngestError.couldNotCreateFile(destination.lastPathComponent)
        }

        do {
            let input = try FileHandle(forReadingFrom: source)
            let output = try FileHandle(forWritingTo: partial)
            defer {
                try? input.close()
                try? output.close()
            }

            var hasher = SHA256()
            var copied: Int64 = 0
            while true {
                try Task.checkCancellation()
                let chunk = try autoreleasepool { try input.read(upToCount: chunkSize) }
                guard let chunk, !chunk.isEmpty else { break }
                hasher.update(data: chunk)
                try output.write(contentsOf: chunk)
                copied += Int64(chunk.count)
                onBytes(copied)
            }
            try output.synchronize()
            let streamed = hasher.finalize()

            if let expected, streamed != expected {
                throw IngestError.verificationFailed(source.lastPathComponent)
            }
            guard try sha256(of: partial, bypassingCache: true) == streamed else {
                throw IngestError.verificationFailed(destination.lastPathComponent)
            }

            let values = try? source.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
            var attributes: [FileAttributeKey: Any] = [:]
            if let modified = values?.contentModificationDate { attributes[.modificationDate] = modified }
            if let created = values?.creationDate { attributes[.creationDate] = created }
            if !attributes.isEmpty { try? fileManager.setAttributes(attributes, ofItemAtPath: partial.path) }

            try fileManager.moveItem(at: partial, to: destination)
            return streamed
        } catch {
            try? fileManager.removeItem(at: partial)
            throw error
        }
    }

    // MARK: - Backup

    private static func backUp(
        _ files: [IngestedFile],
        digests: [URL: SHA256.Digest],
        to backupOriginals: URL,
        progress: @escaping @Sendable (IngestProgress) -> Void
    ) -> BackupOutcome {
        if let problem = volumeProblem(for: backupOriginals) {
            return .unavailable(problem)
        }

        let sizes = files.map { file in
            Int64((try? file.destinationURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        let totalBytes = sizes.reduce(0, +)
        do {
            try prepareDirectory(backupOriginals, requiring: totalBytes)
        } catch {
            return .unavailable(error.localizedDescription)
        }
        removeStalePartials(in: backupOriginals)

        var copied = 0
        var alreadyPresent = 0
        var failed = 0
        var completedBytes: Int64 = 0

        for (index, file) in files.enumerated() {
            if Task.isCancelled { failed += files.count - index; break }
            let digest = digests[file.destinationURL]
            let size = sizes[index]
            let send = { (bytes: Int64) in
                progress(IngestProgress(
                    phase: .backingUp,
                    completedFiles: index,
                    totalFiles: files.count,
                    completedBytes: completedBytes + bytes,
                    totalBytes: totalBytes,
                    currentFilename: file.destinationURL.lastPathComponent
                ))
            }
            send(0)

            do {
                let source = SourceFile(url: file.destinationURL, kind: file.kind, size: size)
                let placement = try place(source, in: backupOriginals, knownDigest: digest, onBytes: send)
                if placement.alreadyPresent { alreadyPresent += 1 } else { copied += 1 }
            } catch {
                failed += 1
            }
            completedBytes += size
        }

        return failed == 0
            ? .completed(copied: copied, alreadyPresent: alreadyPresent)
            : .partial(copied: copied, failed: failed)
    }

    // MARK: - Helpers

    /// Timestamps within a second count as equal, since HFS+ stores whole seconds.
    private static func sameModificationTime(_ a: URL, _ b: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard
            let first = try? a.resourceValues(forKeys: keys).contentModificationDate,
            let second = try? b.resourceValues(forKeys: keys).contentModificationDate
        else { return false }
        return abs(first.timeIntervalSince(second)) < 1
    }

    /// A reason the backup location cannot be used, or nil. A path under `/Volumes` whose volume
    /// is not mounted must not be created, because that would write to the boot drive instead.
    static func volumeProblem(for directory: URL) -> String? {
        let components = directory.standardizedFileURL.pathComponents
        if components.count > 2, components[1] == "Volumes" {
            let volume = "/Volumes/" + components[2]
            if !FileManager.default.fileExists(atPath: volume) {
                return "\(components[2]) is not connected."
            }
        }
        return nil
    }

    private static func prepareDirectory(_ directory: URL, requiring bytes: Int64) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let values = try? directory.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeNameKey
        ])
        if let available = values?.volumeAvailableCapacityForImportantUsage {
            let margin = Int64(1) << 30
            if available < bytes + margin {
                throw IngestError.notEnoughSpace(
                    needed: bytes,
                    available: available,
                    volume: values?.volumeName ?? directory.path
                )
            }
        }
    }

    private static func removeStalePartials(in directory: URL) {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in entries where name.hasSuffix(partialSuffix) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// SHA-256 of a file. With `bypassingCache`, reads go to the disk rather than the file
    /// cache, so a verification pass checks what was actually written.
    static func sha256(of url: URL, bypassingCache: Bool = false) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        if bypassingCache { _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1) }

        var hasher = SHA256()
        while true {
            let chunk = try autoreleasepool { try handle.read(upToCount: chunkSize) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize()
    }
}
