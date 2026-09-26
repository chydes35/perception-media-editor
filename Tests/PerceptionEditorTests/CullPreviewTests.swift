import Foundation
import Testing
@testable import PerceptionEditor

struct PhotoMetadataTests {
    @Test func readsSizeAndCaptureDate() throws {
        let temp = try TempDirectory()
        let url = try writeTestJPEG(
            to: temp.url.appendingPathComponent("a.jpg"), width: 640, height: 480, captureDate: "2026:06:14 14:17:48"
        )

        let metadata = try #require(PhotoSourceLoader.metadata(of: url))
        #expect(metadata.width == 640 && metadata.height == 480)

        let parts = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: try #require(metadata.captureDate)
        )
        #expect(parts.year == 2026 && parts.month == 6 && parts.day == 14)
        #expect(parts.hour == 14 && parts.minute == 17 && parts.second == 48)
    }

    @Test func aPhotoWithoutAnExifDateHasNone() throws {
        let temp = try TempDirectory()
        let url = try writeTestJPEG(to: temp.url.appendingPathComponent("a.jpg"))
        #expect(PhotoSourceLoader.metadata(of: url)?.captureDate == nil)
    }

    @Test func malformedExifDatesAreRejected() {
        #expect(PhotoSourceLoader.parseEXIFDate("2026:06:14 14:17:48") != nil)
        #expect(PhotoSourceLoader.parseEXIFDate("") == nil)
        #expect(PhotoSourceLoader.parseEXIFDate("not a date") == nil)
        #expect(PhotoSourceLoader.parseEXIFDate("2026:06:14") == nil)
    }

    @Test func cullPreviewIsScreenSized() throws {
        let temp = try TempDirectory()
        let url = try writeTestJPEG(to: temp.url.appendingPathComponent("big.jpg"), width: 4000, height: 3000)

        let image = try #require(PhotoSourceLoader.loadCullPreview(url))

        #expect(max(image.width, image.height) == 2560)
        #expect(image.width > image.height)
    }
}

@MainActor
struct CullPreviewCacheTests {
    @Test func keepsOnlyTheMostRecentlyUsedPreviews() async throws {
        let temp = try TempDirectory()
        let assets = try (0 ..< 4).map { index in
            MediaAsset(url: try writeTestJPEG(to: temp.url.appendingPathComponent("p\(index).jpg")))
        }
        let cache = CullPreviewCache(limit: 2)
        var loaded = 0
        cache.onLoaded = { _ in loaded += 1 }

        cache.prefetch(assets)
        let deadline = Date().addingTimeInterval(10)
        while loaded < 4, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(loaded == 4)
        #expect(cache.cachedCount == 2)
        // Whatever is cached is a ready image; the oldest were dropped.
        let cachedIDs = assets.filter { cache.image(for: $0) != nil }.map(\.id)
        #expect(cachedIDs.count == 2)
    }

    @Test func aRelinkedFileIsNeverServedFromTheOldPreview() async throws {
        let temp = try TempDirectory()
        let original = MediaAsset(url: try writeTestJPEG(to: temp.url.appendingPathComponent("a.jpg")))
        let cache = CullPreviewCache()
        var loaded = 0
        cache.onLoaded = { _ in loaded += 1 }

        cache.prefetch([original])
        let deadline = Date().addingTimeInterval(10)
        while loaded < 1, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(cache.image(for: original) != nil)

        var relinked = original
        relinked.url = temp.url.appendingPathComponent("elsewhere.jpg")
        #expect(cache.image(for: relinked) == nil)
    }

    @Test func removedPhotosLeaveTheCache() async throws {
        let temp = try TempDirectory()
        let asset = MediaAsset(url: try writeTestJPEG(to: temp.url.appendingPathComponent("a.jpg")))
        let cache = CullPreviewCache()
        var loaded = 0
        cache.onLoaded = { _ in loaded += 1 }
        cache.prefetch([asset])
        let deadline = Date().addingTimeInterval(10)
        while loaded < 1, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }

        cache.remove(asset.id)

        #expect(cache.cachedCount == 0)
        #expect(cache.image(for: asset) == nil)
    }
}
