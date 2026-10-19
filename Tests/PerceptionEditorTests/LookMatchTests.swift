import CoreGraphics
import CoreImage
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

private enum LookMatchFixture {
    /// A gray gradient with a warm and a cool patch: neutral evidence plus some color.
    static func scene() -> CIImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let width = 320, height = 240
        var buffer = [Float]()
        buffer.reserveCapacity(width * height * 4)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let value = Float(0.1 + 0.7 * Double(x) / Double(width - 1))
                if y < 40 && x < 120 {
                    buffer += [0.75, 0.45, 0.3, 1]
                } else if y > 200 && x > 200 {
                    buffer += [0.2, 0.35, 0.6, 1]
                } else {
                    buffer += [value, value, value, 1]
                }
            }
        }
        let data = buffer.withUnsafeBytes { Data($0) }
        return CIImage(bitmapData: data, bytesPerRow: width * 16, size: CGSize(width: width, height: height),
                       format: .RGBAf, colorSpace: space)
    }

    static func write(_ image: CIImage, to url: URL) throws -> URL {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        try CIContext().writePNGRepresentation(of: image, to: url, format: .RGBA16, colorSpace: space)
        return url
    }

    static func darkened(_ image: CIImage, ev: Double) -> CIImage {
        image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: ev])
    }

    static func rawInfo(temperature: Double, tint: Double) -> RawInfo {
        RawInfo(asShotTemperature: temperature, asShotTint: tint, defaultLuminanceNoiseReduction: 0,
                defaultColorNoiseReduction: 0, defaultSharpness: 0, defaultDetail: 0,
                supportsNoiseReduction: true, supportsSharpness: true, supportsDetail: true,
                supportsLensCorrection: false, lensCorrectionDefault: false)
    }

    static var heroLook: PhotoAdjustments {
        var look = PhotoAdjustments.neutral
        look.exposure = 0.2
        look.contrast = 0.1
        look.vibrance = 0.15
        return look
    }

    /// One scene whatever the signals say, for checking the solve on its own.
    static var oneScene: LookMatchThresholds {
        var thresholds = LookMatchThresholds.default
        thresholds.captureGapSeconds = .infinity
        thresholds.miredStep = .infinity
        thresholds.exposureStep = .infinity
        thresholds.featurePrintDistance = .infinity
        return thresholds
    }
}

struct LookMatchAnalyzerTests {
    @Test func rawWhiteBalanceOffsetIsCarriedInMired() {
        let heroAsShot = LookMatchFixture.rawInfo(temperature: 5000, tint: 4)
        let targetAsShot = LookMatchFixture.rawInfo(temperature: 6000, tint: -2)
        var hero = RawSettings()
        hero.temperature = 4500
        hero.tint = 10
        let carried = LookMatchAnalyzer.carriedWhiteBalance(hero: hero, heroAsShot: heroAsShot, targetAsShot: targetAsShot)
        // 1e6/4500 − 1e6/5000 = 22.22 mired warmer; 1e6/6000 + 22.22 = 188.89 mired → 5294 K.
        #expect(carried.0 == 5294)
        // Tint moves by the same amount as the hero's: +6.
        #expect(carried.1 == 4)
        // The same Kelvin change would have given 5500 K: mired keeps the visual step.
        #expect(carried.0 != 5500)
    }

    @Test func heroOnAsShotWhiteBalanceKeepsTheTargetOnAsShot() {
        let carried = LookMatchAnalyzer.carriedWhiteBalance(
            hero: RawSettings(), heroAsShot: LookMatchFixture.rawInfo(temperature: 5000, tint: 0),
            targetAsShot: LookMatchFixture.rawInfo(temperature: 3200, tint: 5))
        #expect(carried.0 == nil && carried.1 == nil)
        // Only the tint edited: temperature offset is zero, so the target keeps its own as-shot Kelvin.
        var tintOnly = RawSettings()
        tintOnly.tint = 8
        let partial = LookMatchAnalyzer.carriedWhiteBalance(
            hero: tintOnly, heroAsShot: LookMatchFixture.rawInfo(temperature: 5000, tint: 2),
            targetAsShot: LookMatchFixture.rawInfo(temperature: 3200, tint: 5))
        #expect(partial.0 == 3200 && partial.1 == 11)
    }

    @Test func aFrameOneStopDarkerSolvesToOneStopMoreExposure() throws {
        let folder = try TempDirectory()
        let scene = LookMatchFixture.scene()
        let heroURL = try LookMatchFixture.write(scene, to: folder.url.appendingPathComponent("hero.png"))
        let targetURL = try LookMatchFixture.write(LookMatchFixture.darkened(scene, ev: -1),
                                                   to: folder.url.appendingPathComponent("target.png"))
        let before = try [Data(contentsOf: heroURL), Data(contentsOf: targetURL)]
        let hero = LookMatchPhoto(id: UUID(), url: heroURL, adjustments: LookMatchFixture.heroLook)
        let target = LookMatchPhoto(id: UUID(), url: targetURL, adjustments: .neutral)

        let result = try LookMatchAnalyzer().analyze(LookMatchRequest(
            photos: [hero, target], selectedID: nil, thresholds: LookMatchFixture.oneScene))

        let scene0 = try #require(result.scenes.first)
        #expect(result.scenes.count == 1)
        #expect(scene0.heroID == hero.id)
        let proposal = try #require(scene0.proposals.first)
        #expect(proposal.targetID == target.id)
        #expect(abs(proposal.adjustments.exposure - (LookMatchFixture.heroLook.exposure + 1)) <= 0.1)
        #expect(proposal.adjustments.contrast == LookMatchFixture.heroLook.contrast)
        #expect(proposal.adjustments.vibrance == LookMatchFixture.heroLook.vibrance)
        #expect(abs(proposal.adjustments.temperature) < 0.05 && abs(proposal.adjustments.tint) < 0.05)
        #expect(proposal.confidence >= 0.8)
        #expect(!proposal.isFlagged)
        // Analysis only reads the originals.
        #expect(try [Data(contentsOf: heroURL), Data(contentsOf: targetURL)] == before)
    }

    @Test func exposureIsClampedToOneAndAHalfStopsAndTheProposalIsFlagged() throws {
        let folder = try TempDirectory()
        let scene = LookMatchFixture.scene()
        let heroURL = try LookMatchFixture.write(scene, to: folder.url.appendingPathComponent("hero.png"))
        let targetURL = try LookMatchFixture.write(LookMatchFixture.darkened(scene, ev: -3),
                                                   to: folder.url.appendingPathComponent("target.png"))
        let hero = LookMatchPhoto(id: UUID(), url: heroURL, adjustments: LookMatchFixture.heroLook)
        let target = LookMatchPhoto(id: UUID(), url: targetURL, adjustments: .neutral)
        let result = try LookMatchAnalyzer().analyze(LookMatchRequest(
            photos: [hero, target], selectedID: nil, thresholds: LookMatchFixture.oneScene))
        let proposal = try #require(result.scenes.first?.proposals.first)
        #expect(abs(proposal.adjustments.exposure - (LookMatchFixture.heroLook.exposure + 1.5)) < 0.011)
        #expect(proposal.isFlagged)
        #expect(proposal.confidence < LookMatchThresholds.default.minimumConfidence)
    }

    @Test func editedTargetsAreSkippedAndLocalWorkStaysWithItsPhoto() throws {
        let folder = try TempDirectory()
        let scene = LookMatchFixture.scene()
        let heroURL = try LookMatchFixture.write(scene, to: folder.url.appendingPathComponent("hero.png"))
        let editedURL = try LookMatchFixture.write(scene, to: folder.url.appendingPathComponent("edited.png"))
        let localURL = try LookMatchFixture.write(scene, to: folder.url.appendingPathComponent("local.png"))

        var heroLook = LookMatchFixture.heroLook
        heroLook.masks = [LocalMask(name: "Brush", shape: .brush(strokes: []))]
        var edited = PhotoAdjustments.neutral
        edited.saturation = -0.3
        var local = PhotoAdjustments.neutral
        local.cropRect = CropRect(x: 0.1, y: 0.1, width: 0.7, height: 0.7)
        local.rotationQuarterTurns = 1
        local.straightenDegrees = 2
        local.retouches = [RetouchStroke(kind: .clone, points: [NormalizedPoint(x: 0.5, y: 0.5)],
                                         source: NormalizedPoint(x: 0.3, y: 0.3), size: 0.03, feather: 0.5)]
        local.masks = [LocalMask(name: "Target brush", shape: .brush(strokes: []))]

        let ids = (hero: UUID(), edited: UUID(), local: UUID())
        let result = try LookMatchAnalyzer().analyze(LookMatchRequest(photos: [
            LookMatchPhoto(id: ids.hero, url: heroURL, adjustments: heroLook),
            LookMatchPhoto(id: ids.edited, url: editedURL, adjustments: edited),
            LookMatchPhoto(id: ids.local, url: localURL, adjustments: local)
        ], selectedID: ids.hero, thresholds: LookMatchFixture.oneScene))

        let scene0 = try #require(result.scenes.first)
        #expect(scene0.alreadyEdited == [ids.edited])
        #expect(!scene0.proposals.contains { $0.targetID == ids.edited })
        let proposal = try #require(scene0.proposals.first { $0.targetID == ids.local })
        #expect(proposal.adjustments.cropRect == local.cropRect)
        #expect(proposal.adjustments.rotationQuarterTurns == 1)
        #expect(proposal.adjustments.straightenDegrees == 2)
        #expect(proposal.adjustments.retouches == local.retouches)
        // The target keeps its own brush; the hero's brush does not travel.
        #expect(proposal.adjustments.masks.map(\.name) == ["Target brush"])
    }

    @Test func aSceneWithoutAnEditGetsNoProposalsAndASuggestedHero() throws {
        let folder = try TempDirectory()
        let scene = LookMatchFixture.scene()
        let photos = try (0 ..< 3).map { index in
            LookMatchPhoto(id: UUID(), url: try LookMatchFixture.write(
                LookMatchFixture.darkened(scene, ev: index == 1 ? 0 : -1.5),
                to: folder.url.appendingPathComponent("p\(index).png")), adjustments: .neutral)
        }
        let result = try LookMatchAnalyzer().analyze(LookMatchRequest(
            photos: photos, selectedID: nil, thresholds: LookMatchFixture.oneScene))
        let scene0 = try #require(result.scenes.first)
        #expect(scene0.heroID == nil)
        #expect(scene0.proposals.isEmpty)
        // The best-exposed frame is suggested.
        #expect(scene0.suggestedHeroID == photos[1].id)
    }

    @Test func cancellationStopsTheAnalysis() async throws {
        let folder = try TempDirectory()
        let url = try LookMatchFixture.write(LookMatchFixture.scene(), to: folder.url.appendingPathComponent("a.png"))
        let request = LookMatchRequest(photos: [
            LookMatchPhoto(id: UUID(), url: url, adjustments: LookMatchFixture.heroLook),
            LookMatchPhoto(id: UUID(), url: url, adjustments: .neutral)
        ], selectedID: nil, thresholds: LookMatchFixture.oneScene)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await LookMatchService().analyze(request)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test(.enabled(if: RawSample.isAvailable))
    func rawTargetsGetTheHerosWhiteBalanceOffsetFromTheirOwnAsShot() throws {
        let directory = try #require(RawSample.url).deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.uppercased().hasSuffix(".RW2") }.sorted().prefix(2)
            .map { directory.appendingPathComponent($0) }
        try #require(files.count == 2)
        let before = try files.map { try Data(contentsOf: $0) }
        let heroInfo = try #require(PhotoSourceLoader.rawInfo(of: files[0]))
        let targetInfo = try #require(PhotoSourceLoader.rawInfo(of: files[1]))
        var look = LookMatchFixture.heroLook
        look.raw.temperature = (heroInfo.asShotTemperature - 600).rounded()
        look.raw.tint = (heroInfo.asShotTint + 5).rounded()
        let hero = LookMatchPhoto(id: UUID(), url: files[0], adjustments: look)
        let target = LookMatchPhoto(id: UUID(), url: files[1], adjustments: .neutral)

        let result = try LookMatchAnalyzer().analyze(LookMatchRequest(
            photos: [hero, target], selectedID: hero.id, thresholds: LookMatchFixture.oneScene))
        let proposal = try #require(result.scenes.first?.proposals.first)
        let expected = LookMatchAnalyzer.carriedWhiteBalance(hero: look.raw, heroAsShot: heroInfo, targetAsShot: targetInfo)
        #expect(proposal.adjustments.raw.temperature == expected.0)
        #expect(proposal.adjustments.raw.tint == expected.1)
        #expect(abs(proposal.adjustments.exposure - look.exposure) <= 1.5)
        #expect(try files.map { try Data(contentsOf: $0) } == before)
    }
}
