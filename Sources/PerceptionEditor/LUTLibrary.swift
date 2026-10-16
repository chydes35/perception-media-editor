import CryptoKit
import Foundation

/// A LUT the project uses, identified by the SHA-256 of its file so the same table imported twice,
/// or from two places, is one LUT.
struct LUTReference: Codable, Hashable, Sendable, Identifiable {
    var contentHash: String
    var displayName: String

    var id: String { contentHash }
}

/// A creative LUT on a photo or clip: the table, blended over the image by `intensity` (0…1).
struct LUTApplication: Codable, Equatable, Sendable {
    var reference: LUTReference
    var intensity = 1.0
}

/// Parsed LUTs by content hash, shared by every renderer (preview, thumbnails, export, video). The
/// store loads what a project references; a renderer that finds nothing here renders without it.
final class LoadedLUTs: @unchecked Sendable {
    static let shared = LoadedLUTs()
    private let lock = NSLock()
    private var luts: [String: CubeLUT] = [:]

    func lut(_ hash: String) -> CubeLUT? {
        lock.lock()
        defer { lock.unlock() }
        return luts[hash]
    }

    /// For tests that need a LUT to be found on disk again.
    func remove(_ hash: String) {
        lock.lock()
        defer { lock.unlock() }
        luts.removeValue(forKey: hash)
    }

    func insert(_ lut: CubeLUT, hash: String) {
        lock.lock()
        defer { lock.unlock() }
        luts[hash] = lut
    }
}

/// Imported LUTs. A copy of each lives in the library folder (`<sha256>.cube`, with an index of
/// display names); a project also keeps copies next to itself (`LUTs/<sha256 prefix>-<name>.cube`)
/// so it opens on another Mac. Source files are only ever read.
final class LUTLibrary: @unchecked Sendable {
    static func defaultDirectory() -> URL {
        if TestIsolation.isRunningTests {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("PerceptionEditorTests-LUTLibrary-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Perception Media Editor/LUT Library", isDirectory: true)
    }

    static let projectFolderName = "LUTs"

    let directory: URL
    private let lock = NSLock()
    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    init(directory: URL = LUTLibrary.defaultDirectory()) {
        self.directory = directory
    }

    /// Reads, validates and stores a copy of `source`. Throws a readable error for a bad file.
    @discardableResult
    func importLUT(from source: URL) throws -> LUTReference {
        let lut = try CubeLUT(contentsOf: source) // Validates size and content before anything is written.
        let data = try Data(contentsOf: source)
        let hash = Self.hash(data)
        let reference = LUTReference(contentHash: hash, displayName: source.deletingPathExtension().lastPathComponent)
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stored = directory.appendingPathComponent("\(hash).cube")
        if !FileManager.default.fileExists(atPath: stored.path) {
            try data.write(to: stored, options: .atomic)
        }
        var index = readIndex()
        if index[hash] == nil {
            index[hash] = reference.displayName
            try writeIndex(index)
        }
        LoadedLUTs.shared.insert(lut, hash: hash)
        return LUTReference(contentHash: hash, displayName: index[hash] ?? reference.displayName)
    }

    /// Everything in the library, by name.
    func references() -> [LUTReference] {
        lock.lock()
        defer { lock.unlock() }
        return readIndex()
            .filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent("\($0.key).cube").path) }
            .map { LUTReference(contentHash: $0.key, displayName: $0.value) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// The parsed LUT: already loaded, or from the project's own copy, or from the library. Every
    /// file is checked against the hash, so a renamed or edited copy is not used. Nil when missing.
    func load(_ reference: LUTReference, projectFolder: URL?) -> CubeLUT? {
        if let loaded = LoadedLUTs.shared.lut(reference.contentHash) { return loaded }
        var candidates: [URL] = []
        if let projectFolder {
            candidates.append(projectFolder.appendingPathComponent(Self.projectFolderName).appendingPathComponent(Self.projectFileName(for: reference)))
        }
        candidates.append(directory.appendingPathComponent("\(reference.contentHash).cube"))
        for url in candidates {
            guard let data = try? Data(contentsOf: url), Self.hash(data) == reference.contentHash,
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
                  let lut = try? CubeLUT(parsing: text) else { continue }
            LoadedLUTs.shared.insert(lut, hash: reference.contentHash)
            return lut
        }
        return nil
    }

    /// Puts a copy of each LUT next to the project, so the shoot folder is self-contained.
    func copy(_ references: Set<LUTReference>, intoProjectFolder folder: URL) throws {
        guard !references.isEmpty else { return }
        let target = folder.appendingPathComponent(Self.projectFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for reference in references {
            let destination = target.appendingPathComponent(Self.projectFileName(for: reference))
            if FileManager.default.fileExists(atPath: destination.path) { continue }
            let stored = directory.appendingPathComponent("\(reference.contentHash).cube")
            guard let data = try? Data(contentsOf: stored), Self.hash(data) == reference.contentHash else { continue }
            try data.write(to: destination, options: .atomic)
        }
    }

    static func projectFileName(for reference: LUTReference) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_."))
        let name = String(reference.displayName.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }).prefix(60)
        return "\(reference.contentHash.prefix(12))-\(name).cube"
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func readIndex() -> [String: String] {
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return index
    }

    private func writeIndex(_ index: [String: String]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(index).write(to: indexURL, options: .atomic)
    }
}
