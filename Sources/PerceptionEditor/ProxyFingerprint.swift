// Sources/PerceptionEditor/ProxyFingerprint.swift
import CryptoKit
import Foundation

/// Identifies a source file by content, not path, so a clip that is copied, moved, or relinked
/// keeps its proxy. Reads at most 2 MiB: the size plus the first and last mebibyte.
enum ProxyFingerprint {
    static let sampleBytes = 1_048_576
    /// Bumped when existing proxies must be regenerated. 2: full-range sources are converted to video
    /// range correctly; version-1 proxies of them play about 17% too bright.
    static let formatVersion = 2

    /// Version 1 keys carry no version prefix, so they match the proxies already on disk.
    static func key(for url: URL, formatVersion: Int = formatVersion) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        var hasher = SHA256()
        if formatVersion > 1 { hasher.update(data: Data("v\(formatVersion)|".utf8)) }
        hasher.update(data: Data("\(size)|".utf8))
        try handle.seek(toOffset: 0)
        hasher.update(data: try handle.read(upToCount: sampleBytes) ?? Data())
        if size > UInt64(sampleBytes) {
            try handle.seek(toOffset: size - UInt64(min(UInt64(sampleBytes), size - UInt64(sampleBytes))))
            hasher.update(data: try handle.readToEnd() ?? Data())
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
