import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PerceptionEditor

/// Writes a gradient JPEG carrying EXIF exposure settings.
private func writeExposureJPEG(to url: URL, iso: Int, exposureTime: Double, fNumber: Double) throws -> URL {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = try #require(CGContext(
        data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(srgbColor(0.5, 0.5, 0.5))
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, [
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifISOSpeedRatings: [iso],
            kCGImagePropertyExifExposureTime: exposureTime,
            kCGImagePropertyExifFNumber: fNumber
        ]
    ] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return url
}

struct LookMatchExposureMetadataTests {
    @Test func readsExposureSettingsAndComputesSceneExposureValue() throws {
        let folder = try TempDirectory()
        let url = try writeExposureJPEG(to: folder.url.appendingPathComponent("a.jpg"),
                                        iso: 400, exposureTime: 1.0 / 125, fNumber: 4)
        let exposure = try #require(ExposureMetadata.read(url))
        #expect(exposure.iso == 400)
        #expect(abs(exposure.exposureTime - 0.008) < 1e-9)
        #expect(exposure.fNumber == 4)
        // log2(16 / 0.008) − log2(4) = log2(2000) − 2 ≈ 8.966
        #expect(abs(exposure.exposureValue - (log2(2000.0) - 2)) < 1e-9)
    }

    @Test func equivalentExposuresOfTheSameLightHaveTheSameValue() {
        let a = ExposureMetadata(iso: 100, exposureTime: 1.0 / 250, fNumber: 2.8)
        let b = ExposureMetadata(iso: 200, exposureTime: 1.0 / 500, fNumber: 2.8)
        let c = ExposureMetadata(iso: 100, exposureTime: 1.0 / 125, fNumber: 4)
        #expect(abs(a.exposureValue - b.exposureValue) < 1e-9)
        #expect(abs(a.exposureValue - c.exposureValue) < 0.05)
    }

    @Test func missingExposureSettingsReturnNil() throws {
        let folder = try TempDirectory()
        let url = try writeTestJPEG(to: folder.url.appendingPathComponent("plain.jpg"))
        #expect(ExposureMetadata.read(url) == nil)
    }

    @Test(.enabled(if: RawSample.isAvailable))
    func readsExposureSettingsFromALumixRAW() throws {
        let url = try #require(RawSample.url)
        let exposure = try #require(ExposureMetadata.read(url))
        #expect(exposure.iso >= 50 && exposure.iso <= 204_800)
        #expect(exposure.exposureTime > 0 && exposure.exposureTime < 120)
        #expect(exposure.fNumber >= 0.95 && exposure.fNumber <= 32)
        #expect(exposure.exposureValue.isFinite)
    }
}
