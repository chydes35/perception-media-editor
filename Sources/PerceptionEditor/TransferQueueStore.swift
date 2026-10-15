import Foundation

/// Persists transfer records as one JSON file, replaced atomically on every change. It lives
/// beside, not inside, the `.pmedit` project so a project schema migration is never needed for
/// connectivity, and it never holds credentials or signed URLs.
actor TransferQueueStore {
    private struct FileFormat: Codable {
        var version = 1
        var transfers: [TransferRecord]
    }

    private let fileURL: URL
    private var loaded: [TransferRecord]?
    private var loadWarningText: String?

    /// Loading is lazy: creating the store (as every `EditorStore` does, including in tests)
    /// never touches the file on disk.
    init(fileURL: URL) { self.fileURL = fileURL }

    private var records: [TransferRecord] {
        get { ensureLoaded() }
        set { loaded = newValue }
    }

    private func ensureLoaded() -> [TransferRecord] {
        if let loaded { return loaded }
        let (records, warning) = Self.load(from: fileURL)
        loaded = records
        loadWarningText = warning
        return records
    }

    /// Set when the file existed but could not be read and was moved aside.
    func loadWarning() -> String? {
        _ = ensureLoaded()
        return loadWarningText
    }

    static func defaultFileURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent("PerceptionMediaEditor", isDirectory: true)
            .appendingPathComponent("StudioOSTransfers.json")
    }

    func all() -> [TransferRecord] { records }

    func record(id: String) -> TransferRecord? { records.first { $0.id == id } }

    func upsert(_ record: TransferRecord) throws {
        var updated = records
        if let index = updated.firstIndex(where: { $0.id == record.id }) {
            updated[index] = record
        } else {
            updated.append(record)
        }
        try write(updated)
        records = updated
    }

    @discardableResult
    func update(id: String, _ mutate: (inout TransferRecord) -> Void) throws -> TransferRecord {
        guard var record = records.first(where: { $0.id == id }) else { throw CocoaError(.fileNoSuchFile) }
        mutate(&record)
        try upsert(record)
        return record
    }

    func remove(id: String) throws {
        let updated = records.filter { $0.id != id }
        try write(updated)
        records = updated
    }

    // MARK: - Persistence

    private func write(_ transfers: [TransferRecord]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(FileFormat(transfers: transfers)).write(to: fileURL, options: .atomic)
    }

    private static func load(from fileURL: URL) -> ([TransferRecord], String?) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return ([], nil) }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let data = try Data(contentsOf: fileURL)
            return (try decoder.decode(FileFormat.self, from: data).transfers, nil)
        } catch {
            // Keep the unreadable file for inspection and start clean rather than crash the app.
            let stamp = Int(Date().timeIntervalSince1970)
            let aside = fileURL.deletingLastPathComponent()
                .appendingPathComponent("\(fileURL.lastPathComponent).corrupt-\(stamp)")
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            return ([], "The Studio OS transfer list could not be read and was set aside as \(aside.lastPathComponent).")
        }
    }
}
