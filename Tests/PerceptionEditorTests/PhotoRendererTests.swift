import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PerceptionEditor

struct PhotoRendererTests {
    /// Writes a gradient JPEG. Orientation 6 means "rotate 90° clockwise to display",
    /// so a 400×300 file displays as 300×400.
    private func makeJPEG(width: Int = 400, height: Int = 300, orientation: Int = 1) throws -> URL {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let gradient = try #require(CGGradient(
            colorsSpace: space,
            colors: [CGColor(red: 0.1, green: 0.2, blue: 0.8, alpha: 1), CGColor(red: 0.9, green: 0.6, blue: 0.1, alpha: 1)] as CFArray,
            locations: nil
        ))
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        let image = try #require(context.makeImage())

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pme-test-\(UUID().uuidString).jpg")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test func dimensionsComeFromMetadataAndRespectOrientation() throws {
        let upright = try makeJPEG()
        let rotated = try makeJPEG(orientation: 6)
        defer {
            try? FileManager.default.removeItem(at: upright)
            try? FileManager.default.removeItem(at: rotated)
        }

        #expect(PhotoSourceLoader.dimensions(of: upright).map { [$0.width, $0.height] } == [400, 300])
        #expect(PhotoSourceLoader.dimensions(of: rotated).map { [$0.width, $0.height] } == [300, 400])
        #expect(PhotoSourceLoader.dimensions(of: URL(fileURLWithPath: "/nonexistent.jpg")) == nil)
    }

    @Test func previewIsCappedAndHasAHistogram() async throws {
        let url = try makeJPEG(width: 3000, height: 2000)
        defer { try? FileManager.default.removeItem(at: url) }

        let renderer = PhotoRenderer()
        let result = try #require(await renderer.preview(url: url, adjustments: .neutral))

        #expect(max(result.edited.cgImage.width, result.edited.cgImage.height) == Int(PhotoRenderer.previewDimension))
        #expect(result.histogram.hasValues)
    }

    @Test func previewAppliesOrientationAndCrop() async throws {
        let url = try makeJPEG(orientation: 6)
        defer { try? FileManager.default.removeItem(at: url) }

        var adjustments = PhotoAdjustments.neutral
        adjustments.cropAspect = .square
        let renderer = PhotoRenderer()

        let original = try #require(await renderer.original(url: url))
        #expect(original.cgImage.width == 300 && original.cgImage.height == 400)

        let cropped = try #require(await renderer.preview(url: url, adjustments: adjustments))
        #expect(cropped.edited.cgImage.width == cropped.edited.cgImage.height)
    }

    @Test func workingCacheStaysWithinItsLimit() async throws {
        let urls = try (0 ..< 4).map { _ in try makeJPEG() }
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }

        let renderer = PhotoRenderer(workingCacheLimit: 2)
        for url in urls {
            _ = await renderer.preview(url: url, adjustments: .neutral)
        }
        #expect(await renderer.cachedWorkingSourceCount == 2)

        await renderer.evict(url: urls[3])
        #expect(await renderer.cachedWorkingSourceCount == 1)
    }

    @Test func thumbnailIsSmall() async throws {
        let url = try makeJPEG(width: 3000, height: 2000)
        defer { try? FileManager.default.removeItem(at: url) }

        let thumbnail = try #require(await PhotoRenderer().thumbnail(url: url, adjustments: .neutral))
        #expect(max(thumbnail.cgImage.width, thumbnail.cgImage.height) <= Int(PhotoRenderer.thumbnailDimension))
    }

    @Test func exportWritesFullResolutionOrientedPixels() async throws {
        let url = try makeJPEG(width: 3000, height: 2000, orientation: 6)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("pme-export-\(UUID().uuidString).jpg")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: output)
        }

        try await PhotoRenderer(workingCacheLimit: 0).export(
            url: url,
            adjustments: PhotoAdjustments(exposure: 0.3),
            to: output,
            type: .jpeg
        )

        let size = try #require(PhotoSourceLoader.dimensions(of: output))
        #expect(size.width == 2000 && size.height == 3000)
    }

    @Test func exportOfMissingFileThrows() async {
        await #expect(throws: PhotoRenderError.self) {
            try await PhotoRenderer().export(
                url: URL(fileURLWithPath: "/nonexistent.jpg"),
                adjustments: .neutral,
                to: FileManager.default.temporaryDirectory.appendingPathComponent("never.jpg"),
                type: .jpeg
            )
        }
    }
}
