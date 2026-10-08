import AppKit
import CryptoKit
import Foundation
import ImageIO

/// The sole owner of cached photo/video thumbnails. The UI observes a revision counter,
/// rather than retaining another dictionary of images that would defeat eviction.
@MainActor
final class ThumbnailCache {
    private struct Entry {
        var url: URL
        var adjustments: PhotoAdjustments
        var image: NSImage
        var cost: Int
    }

    private let directory: URL
    private let fileManager: FileManager
    let memoryLimitBytes: Int
    private var memory: [UUID: Entry] = [:]
    private var order: [UUID] = []
    private(set) var cachedMemoryBytes = 0
    var cachedCount: Int { memory.count }

    init(directory: URL? = nil, fileManager: FileManager = .default, memoryLimitBytes: Int = 32 * 1_024 * 1_024) {
        self.fileManager = fileManager
        self.memoryLimitBytes = max(0, memoryLimitBytes)
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.directory = directory ?? support
            .appendingPathComponent("Perception Media Editor", isDirectory: true)
            .appendingPathComponent("Thumbnail Cache", isDirectory: true)
        try? fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    func image(for asset: MediaAsset, adjustments: PhotoAdjustments) -> NSImage? {
        // No metadata or disk access on redraws for resident thumbnails.
        if let entry = memory[asset.id], entry.url == asset.url, entry.adjustments == adjustments {
            touch(asset.id)
            return entry.image
        }
        let url = directory.appendingPathComponent(cacheKey(for: asset, adjustments: adjustments)).appendingPathExtension("jpg")
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(PhotoRenderer.thumbnailDimension),
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary)
        else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        retain(image, for: asset, adjustments: adjustments, cost: cgImage.bytesPerRow * cgImage.height)
        return image
    }

    /// Keeps the previous version visible while a replacement renders, within the same budget.
    func previousImage(for asset: MediaAsset) -> NSImage? {
        guard let entry = memory[asset.id], entry.url == asset.url else { return nil }
        touch(asset.id)
        return entry.image
    }

    func store(_ image: NSImage, for asset: MediaAsset, adjustments: PhotoAdjustments) {
        let key = cacheKey(for: asset, adjustments: adjustments)
        invalidate(assetID: asset.id)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        retain(image, for: asset, adjustments: adjustments, cost: cgImage.bytesPerRow * cgImage.height)

        // Encode directly from the bitmap, avoiding a temporary TIFF and a second bitmap copy.
        let url = directory.appendingPathComponent(key).appendingPathExtension("jpg")
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return }
        try? (data as Data).write(to: url, options: .atomic)
    }

    private func retain(_ image: NSImage, for asset: MediaAsset, adjustments: PhotoAdjustments, cost: Int) {
        removeMemory(asset.id)
        guard cost <= memoryLimitBytes else { return }
        memory[asset.id] = Entry(url: asset.url, adjustments: adjustments, image: image, cost: cost)
        cachedMemoryBytes += cost
        touch(asset.id)
        while cachedMemoryBytes > memoryLimitBytes, let oldest = order.first { removeMemory(oldest) }
    }

    private func touch(_ id: UUID) {
        order.removeAll { $0 == id }
        order.append(id)
    }

    private func removeMemory(_ id: UUID) {
        if let removed = memory.removeValue(forKey: id) { cachedMemoryBytes -= removed.cost }
        order.removeAll { $0 == id }
    }

    func invalidate(assetID: UUID) {
        removeMemory(assetID)
        let prefix = assetID.uuidString + "-"
        guard let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for url in contents where url.lastPathComponent.hasPrefix(prefix) { try? fileManager.removeItem(at: url) }
    }

    func clearMemory() {
        memory = [:]
        order = []
        cachedMemoryBytes = 0
    }

    private func cacheKey(for asset: MediaAsset, adjustments: PhotoAdjustments) -> String {
        let modificationDate = (try? asset.url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate?.timeIntervalSinceReferenceDate) ?? 0
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let adjustmentData = (try? encoder.encode(adjustments)) ?? Data()
        var input = Data(asset.url.path.utf8)
        input.append(Data("|\(modificationDate)|".utf8))
        input.append(adjustmentData)
        let digest = SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
        return asset.id.uuidString + "-" + digest
    }
}
