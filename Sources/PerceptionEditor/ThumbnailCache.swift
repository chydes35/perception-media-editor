import AppKit
import CryptoKit
import Foundation

@MainActor
final class ThumbnailCache {
    private let directory: URL
    private let fileManager: FileManager
    private var memory: [String: NSImage] = [:]

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager

        if let directory {
            self.directory = directory
        } else {
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? fileManager.temporaryDirectory
            self.directory = applicationSupport
                .appendingPathComponent("Perception Media Editor", isDirectory: true)
                .appendingPathComponent("Thumbnail Cache", isDirectory: true)
        }

        try? fileManager.createDirectory(
            at: self.directory,
            withIntermediateDirectories: true
        )
    }

    func image(for asset: MediaAsset, adjustments: PhotoAdjustments) -> NSImage? {
        let key = cacheKey(for: asset, adjustments: adjustments)
        if let image = memory[key] { return image }

        let url = directory.appendingPathComponent(key).appendingPathExtension("jpg")
        guard let image = NSImage(contentsOf: url) else { return nil }
        memory[key] = image
        return image
    }

    /// Stores the thumbnail for the asset's current adjustments and replaces any older
    /// versions, so edits do not leave a trail of stale files behind.
    func store(_ image: NSImage, for asset: MediaAsset, adjustments: PhotoAdjustments) {
        let key = cacheKey(for: asset, adjustments: adjustments)
        invalidate(assetID: asset.id)
        memory[key] = image

        guard
            let tiff = image.tiffRepresentation,
            let representation = NSBitmapImageRep(data: tiff),
            let data = representation.representation(
                using: .jpeg,
                properties: [.compressionFactor: 0.82]
            )
        else { return }

        let url = directory.appendingPathComponent(key).appendingPathExtension("jpg")
        try? data.write(to: url, options: .atomic)
    }

    func invalidate(assetID: UUID) {
        let prefix = assetID.uuidString + "-"
        memory = memory.filter { !$0.key.hasPrefix(prefix) }

        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }

        for url in contents where url.lastPathComponent.hasPrefix(prefix) {
            try? fileManager.removeItem(at: url)
        }
    }

    func clearMemory() {
        memory = [:]
    }

    private func cacheKey(for asset: MediaAsset, adjustments: PhotoAdjustments) -> String {
        let modificationDate = (try? asset.url.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate?.timeIntervalSinceReferenceDate) ?? 0
        let adjustmentData = (try? JSONEncoder().encode(adjustments)) ?? Data()
        var input = Data(asset.url.path.utf8)
        input.append(Data("|\(modificationDate)|".utf8))
        input.append(adjustmentData)
        let digest = SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
        return asset.id.uuidString + "-" + digest
    }
}
