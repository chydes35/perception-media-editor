import AppKit
import Foundation
import Testing
@testable import PerceptionEditor

@MainActor
struct ThumbnailMemoryTests {
    @Test func evictionHonorsBytesAndDiskReloadsAnEvictedImage() throws {
        let temp = try TempDirectory()
        let cg = try #require(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
            bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let image = NSImage(cgImage: cg, size: NSSize(width: 64, height: 64))
        let cost = cg.bytesPerRow * cg.height
        let cache = ThumbnailCache(directory: temp.url, memoryLimitBytes: cost * 2)
        let assets = (0..<3).map { MediaAsset(url: temp.url.appendingPathComponent("source\($0).jpg")) }
        cache.store(image, for: assets[0], adjustments: .neutral)
        cache.store(image, for: assets[1], adjustments: .neutral)
        #expect(cache.image(for: assets[0], adjustments: .neutral) === image) // Touch the oldest.
        cache.store(image, for: assets[2], adjustments: .neutral)
        #expect(cache.cachedCount == 2)
        #expect(cache.cachedMemoryBytes <= cache.memoryLimitBytes)
        #expect(cache.previousImage(for: assets[1]) == nil)
        #expect(cache.image(for: assets[1], adjustments: .neutral) != nil) // Still available on disk.
        #expect(cache.cachedMemoryBytes <= cache.memoryLimitBytes)
        cache.clearMemory()
        #expect(cache.cachedMemoryBytes == 0 && cache.cachedCount == 0)
        #expect(cache.image(for: assets[0], adjustments: .neutral) != nil)
    }

    @Test func oversizedImagesRemainOnDiskWithoutExceedingTheBudget() throws {
        let temp = try TempDirectory()
        let url = try writeTestJPEG(to: temp.url.appendingPathComponent("source.jpg"))
        let image = try #require(NSImage(contentsOf: url))
        let asset = MediaAsset(url: url)
        let cache = ThumbnailCache(directory: temp.url.appendingPathComponent("cache"), memoryLimitBytes: 1)
        cache.store(image, for: asset, adjustments: .neutral)
        #expect(cache.cachedCount == 0 && cache.cachedMemoryBytes == 0)
        #expect(cache.image(for: asset, adjustments: .neutral) != nil)
        #expect(cache.cachedMemoryBytes == 0)
        #expect(cache.image(for: asset, adjustments: PhotoAdjustments(exposure: 1)) == nil)
        var relinked = asset
        relinked.url = temp.url.appendingPathComponent("other.jpg")
        #expect(cache.image(for: relinked, adjustments: .neutral) == nil)
    }

    @Test func pressureDropsExpendableThumbnailsWithoutChangingTheProject() throws {
        let temp = try TempDirectory()
        let url = try writeTestJPEG(to: temp.url.appendingPathComponent("source.jpg"))
        let asset = MediaAsset(url: url)
        let store = EditorStore()
        store.project.media = [asset]
        store.thumbnailCache.store(try #require(NSImage(contentsOf: url)), for: asset, adjustments: .neutral)
        let before = store.project
        #expect(store.thumbnailCache.cachedCount == 1)
        store.releaseMemoryUnderPressure()
        #expect(store.thumbnailCache.cachedCount == 0)
        #expect(store.project == before)
    }
}

/// A blocked decoder makes cancellation races reproducible instead of relying on JPEG speed.
private actor BlockedCullDecoder {
    private var permits = 0
    private(set) var startedCount = 0
    private var concurrent = 0
    private(set) var maximumConcurrent = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private let image: RenderedImage

    init(image: CGImage) { self.image = RenderedImage(cgImage: image) }

    func load(_ url: URL) async -> RenderedImage? {
        startedCount += 1
        concurrent += 1
        maximumConcurrent = max(maximumConcurrent, concurrent)
        if permits > 0 { permits -= 1 }
        else { await withCheckedContinuation { waiting.append($0) } }
        concurrent -= 1
        return image
    }

    func release(_ count: Int) {
        permits += count
        while permits > 0, !waiting.isEmpty {
            permits -= 1
            waiting.removeFirst().resume()
        }
    }
}

@Suite(.serialized)
@MainActor
struct CullDecodeSchedulingTests {
    private func decoder() throws -> BlockedCullDecoder {
        let context = try #require(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
            bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return BlockedCullDecoder(image: try #require(context.makeImage()))
    }
    private func waitUntil(_ predicate: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !(await predicate()), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(await predicate())
    }

    @Test func rapidNavigationReplacesQueuedWorkAndNeverExceedsTwoDecodes() async throws {
        let decoder = try decoder()
        defer { Task { await decoder.release(20) } }
        let cache = CullPreviewCache(loader: { await decoder.load($0) })
        let old = (0..<6).map { MediaAsset(url: URL(fileURLWithPath: "/old\($0).jpg")) }
        let latest = (0..<2).map { MediaAsset(url: URL(fileURLWithPath: "/new\($0).jpg")) }
        var loaded: Set<UUID> = []
        cache.onLoaded = { loaded.insert($0) }
        cache.prefetch(old)
        try await waitUntil { await decoder.startedCount == 2 }
        cache.prefetch(latest)
        #expect(cache.activeDecodeCount == 2)
        #expect(cache.queuedDecodeCount == 2)
        await decoder.release(2)
        try await waitUntil { await decoder.startedCount == 4 }
        #expect(loaded.isEmpty)
        await decoder.release(2)
        try await waitUntil { cache.activeDecodeCount == 0 }
        #expect(loaded == Set(latest.map(\.id)))
        #expect(await decoder.startedCount == 4)
        #expect(await decoder.maximumConcurrent == 2)
        #expect(old.allSatisfy { cache.image(for: $0) == nil })
    }

    @Test func clearingCannotRepopulateTheCacheOrFreeSlotsBeforeDecodesReturn() async throws {
        let decoder = try decoder()
        defer { Task { await decoder.release(20) } }
        let cache = CullPreviewCache(loader: { await decoder.load($0) })
        let old = (0..<3).map { MediaAsset(url: URL(fileURLWithPath: "/old\($0).jpg")) }
        let latest = MediaAsset(url: URL(fileURLWithPath: "/new.jpg"))
        var loaded: Set<UUID> = []
        cache.onLoaded = { loaded.insert($0) }
        cache.prefetch(old)
        try await waitUntil { await decoder.startedCount == 2 }
        cache.clear()
        cache.prefetch([latest])
        #expect(cache.activeDecodeCount == 2 && cache.queuedDecodeCount == 1)
        await decoder.release(2)
        try await waitUntil { await decoder.startedCount == 3 }
        #expect(loaded.isEmpty)
        await decoder.release(1)
        try await waitUntil { cache.activeDecodeCount == 0 }
        #expect(loaded == [latest.id])
        #expect(cache.cachedCount == 1)
        #expect(await decoder.maximumConcurrent == 2)
    }

    @Test func failedDecodesDoNotRetryForever() async throws {
        let cache = CullPreviewCache(loader: { _ in nil })
        cache.prefetch([MediaAsset(url: URL(fileURLWithPath: "/missing.jpg"))])
        try await waitUntil { cache.activeDecodeCount == 0 }
        #expect(cache.cachedCount == 0 && cache.queuedDecodeCount == 0)
    }
}
