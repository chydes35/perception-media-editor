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

struct LookMatchSceneTests {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// Five frames that agree on every signal, one second apart.
    private func steadyShoot() -> [SceneSignal] {
        (0 ..< 5).map { index in
            SceneSignal(assetID: UUID(), captureDate: start.addingTimeInterval(Double(index)),
                        asShotMired: 182, exposureValue: 11, featurePrint: [1, 0, 0])
        }
    }

    @Test func steadyLightIsOneScene() {
        let shoot = steadyShoot()
        #expect(LookMatchScenes.group(shoot, thresholds: .default) == [shoot.map(\.assetID)])
    }

    @Test func eachSignalSplitsAScene() {
        let thresholds = LookMatchThresholds.default
        let changes: [(String, (inout SceneSignal) -> Void)] = [
            ("time", { $0.captureDate = $0.captureDate!.addingTimeInterval(thresholds.captureGapSeconds + 1) }),
            ("mired", { $0.asShotMired = $0.asShotMired! + thresholds.miredStep + 1 }),
            ("exposure", { $0.exposureValue = $0.exposureValue! + thresholds.exposureStep + 0.1 }),
            ("feature print", { $0.featurePrint = [0, 1, 0] })
        ]
        for (name, change) in changes {
            var shoot = steadyShoot()
            // The change applies from the fourth frame on, as when the family moves to new light.
            for index in 3 ..< shoot.count {
                change(&shoot[index])
            }
            if name == "time" {
                // Keep later frames one second apart after the gap.
                for index in 4 ..< shoot.count {
                    shoot[index].captureDate = shoot[3].captureDate!.addingTimeInterval(Double(index - 3))
                }
            }
            let scenes = LookMatchScenes.group(shoot, thresholds: thresholds)
            #expect(scenes == [Array(shoot.prefix(3).map(\.assetID)), Array(shoot.suffix(2).map(\.assetID))],
                    "\(name) should split the shoot")
        }
    }

    @Test func changesWithinThresholdsAndMissingSignalsDoNotSplit() {
        var shoot = steadyShoot()
        let thresholds = LookMatchThresholds.default
        shoot[1].asShotMired = 182 + thresholds.miredStep - 1
        shoot[2].exposureValue = nil
        shoot[3].featurePrint = nil
        shoot[4].captureDate = nil
        #expect(LookMatchScenes.group(shoot, thresholds: thresholds).count == 1)
    }

    @Test func groupingFollowsCaptureOrderAndIsStable() {
        let shoot = steadyShoot()
        var shuffled = shoot
        shuffled.swapAt(0, 4)
        shuffled.swapAt(1, 2)
        let first = LookMatchScenes.group(shuffled, thresholds: .default)
        #expect(first == [shoot.map(\.assetID)])
        for _ in 0 ..< 5 { #expect(LookMatchScenes.group(shuffled, thresholds: .default) == first) }
    }

    @Test func heroIsTheSelectedEditedPhotoOrTheMostEditedLatestFrame() {
        let ids = (0 ..< 4).map { _ in UUID() }
        var dates: [UUID: Date] = [:]
        for (index, id) in ids.enumerated() { dates[id] = start.addingTimeInterval(Double(index)) }
        var adjustments: [UUID: PhotoAdjustments] = [:]
        var oneGroup = PhotoAdjustments.neutral
        oneGroup.exposure = 0.3
        var twoGroups = oneGroup
        twoGroups.vibrance = 0.2
        adjustments[ids[0]] = twoGroups
        adjustments[ids[1]] = oneGroup
        adjustments[ids[2]] = twoGroups

        // The most edited groups win; between equals the later frame wins.
        #expect(LookMatchScenes.hero(in: ids, adjustments: adjustments, selectedID: nil, captureDates: dates) == ids[2])
        // A selected, edited photo in the scene wins even with fewer edited groups.
        #expect(LookMatchScenes.hero(in: ids, adjustments: adjustments, selectedID: ids[1], captureDates: dates) == ids[1])
        // A selected photo without a look edit does not.
        #expect(LookMatchScenes.hero(in: ids, adjustments: adjustments, selectedID: ids[3], captureDates: dates) == ids[2])

        // Crop, white balance, brush strokes and retouches alone are not look edits.
        var notALook = PhotoAdjustments.neutral
        notALook.cropRect = CropRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        notALook.raw.temperature = 4800
        notALook.retouches = [RetouchStroke(kind: .heal, points: [NormalizedPoint(x: 0.5, y: 0.5)],
                                           source: NormalizedPoint(x: 0.4, y: 0.4), size: 0.03, feather: 0.5)]
        #expect(LookMatchScenes.lookGroupCount(notALook) == 0)
        #expect(LookMatchScenes.hero(in: [ids[3]], adjustments: [ids[3]: notALook],
                                     selectedID: ids[3], captureDates: dates) == nil)
    }

    @Test func featurePrintsSeparateDifferentPicturesAndMatchCopies() throws {
        let folder = try TempDirectory()
        let quadrants = try writeQuadrantPNG(to: folder.url.appendingPathComponent("q.png"), width: 256, height: 192)
        let gradient = try writeTestJPEG(to: folder.url.appendingPathComponent("g.jpg"), width: 256, height: 192)
        func print(_ url: URL) throws -> [Float] {
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            return try #require(try LookMatchScenes.featurePrint(of: image))
        }
        let a = try print(quadrants), b = try print(quadrants), c = try print(gradient)
        let length = a.reduce(0) { $0 + Double($1) * Double($1) }.squareRoot()
        #expect(abs(length - 1) < 1e-3)
        let same = try #require(LookMatchScenes.featureDistance(a, b))
        let different = try #require(LookMatchScenes.featureDistance(a, c))
        #expect(same < 0.01)
        #expect(different > same + 0.1)
    }
}
