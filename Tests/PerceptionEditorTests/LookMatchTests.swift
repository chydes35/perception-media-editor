import CoreGraphics
import CoreImage
import CryptoKit
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
            #expect(LookMatchScenes.splitReasons(shoot[2], shoot[3], thresholds: thresholds).count == 1,
                    "only \(name) should be named as the reason")
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

    @Test func confidenceFollowsNeutralCastAndToneNotFramingColor() {
        typealias M = LookMatchAnalyzer.Measurement
        let hero = M(median: 0.45, low: 0.05, high: 0.92, neutralRedGreen: 0.02, neutralBlueGreen: -0.03)
        let thresholds = LookMatchThresholds.default
        // Same tone, no neutral area in the target (different clothing or framing): no color penalty.
        let noNeutral = M(median: 0.45, low: 0.05, high: 0.92, neutralRedGreen: nil, neutralBlueGreen: nil)
        #expect(LookMatchAnalyzer.confidence(final: noNeutral, goal: hero, sceneDistance: 0, thresholds: thresholds) == 1)
        // A real cast on the neutral area costs the full color weight.
        let cast = M(median: 0.45, low: 0.05, high: 0.92, neutralRedGreen: 0.2, neutralBlueGreen: -0.15)
        #expect(LookMatchAnalyzer.confidence(final: cast, goal: hero, sceneDistance: 0, thresholds: thresholds) == 0.7)
        // More than half a stop of remaining exposure error costs the full exposure weight.
        let dark = M(median: 0.3, low: 0.05, high: 0.92,
                     neutralRedGreen: 0.02, neutralBlueGreen: -0.03)
        #expect(LookMatchAnalyzer.confidence(final: dark, goal: hero, sceneDistance: 0, thresholds: thresholds) < 0.7)
    }

    @Test func aFrameOneStopDarkerSolvesToOneStopMoreExposure() async throws {
        let folder = try TempDirectory()
        let scene = LookMatchFixture.scene()
        let heroURL = try LookMatchFixture.write(scene, to: folder.url.appendingPathComponent("hero.png"))
        let targetURL = try LookMatchFixture.write(LookMatchFixture.darkened(scene, ev: -1),
                                                   to: folder.url.appendingPathComponent("target.png"))
        let before = try [Data(contentsOf: heroURL), Data(contentsOf: targetURL)]
        let hero = LookMatchPhoto(id: UUID(), url: heroURL, adjustments: LookMatchFixture.heroLook)
        let target = LookMatchPhoto(id: UUID(), url: targetURL, adjustments: .neutral)

        let result = try await LookMatchService().analyze(LookMatchRequest(
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

    @Test func exposureIsClampedToOneAndAHalfStopsAndTheProposalIsFlagged() async throws {
        let folder = try TempDirectory()
        let scene = LookMatchFixture.scene()
        let heroURL = try LookMatchFixture.write(scene, to: folder.url.appendingPathComponent("hero.png"))
        let targetURL = try LookMatchFixture.write(LookMatchFixture.darkened(scene, ev: -3),
                                                   to: folder.url.appendingPathComponent("target.png"))
        let hero = LookMatchPhoto(id: UUID(), url: heroURL, adjustments: LookMatchFixture.heroLook)
        let target = LookMatchPhoto(id: UUID(), url: targetURL, adjustments: .neutral)
        let result = try await LookMatchService().analyze(LookMatchRequest(
            photos: [hero, target], selectedID: nil, thresholds: LookMatchFixture.oneScene))
        let proposal = try #require(result.scenes.first?.proposals.first)
        #expect(abs(proposal.adjustments.exposure - (LookMatchFixture.heroLook.exposure + 1.5)) < 0.011)
        #expect(proposal.isFlagged)
        #expect(proposal.confidence < LookMatchThresholds.default.minimumConfidence)
    }

    @Test func editedTargetsAreSkippedAndLocalWorkStaysWithItsPhoto() async throws {
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
        let result = try await LookMatchService().analyze(LookMatchRequest(photos: [
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

    @Test func aSceneWithoutAnEditGetsNoProposalsAndASuggestedHero() async throws {
        let folder = try TempDirectory()
        let scene = LookMatchFixture.scene()
        let photos = try (0 ..< 3).map { index in
            LookMatchPhoto(id: UUID(), url: try LookMatchFixture.write(
                LookMatchFixture.darkened(scene, ev: index == 1 ? 0 : -1.5),
                to: folder.url.appendingPathComponent("p\(index).png")), adjustments: .neutral)
        }
        let result = try await LookMatchService().analyze(LookMatchRequest(
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

    /// Found on the 2026-10-18 shoot: a photo whose only edit was its white balance got a
    /// proposal that reset it to as-shot. White balance belongs to the photo, so it stays.
    @Test(.enabled(if: RawSample.isAvailable))
    func aTargetsOwnRawWhiteBalanceIsKept() async throws {
        let directory = try #require(RawSample.url).deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.uppercased().hasSuffix(".RW2") }.sorted().prefix(2)
            .map { directory.appendingPathComponent($0) }
        try #require(files.count == 2)
        var look = LookMatchFixture.heroLook
        look.raw.temperature = 4600
        look.raw.tint = 6
        var ownWhiteBalance = PhotoAdjustments.neutral
        ownWhiteBalance.raw.temperature = 5127
        ownWhiteBalance.raw.tint = -3
        let hero = LookMatchPhoto(id: UUID(), url: files[0], adjustments: look)
        let target = LookMatchPhoto(id: UUID(), url: files[1], adjustments: ownWhiteBalance)

        let result = try await LookMatchService().analyze(LookMatchRequest(
            photos: [hero, target], selectedID: hero.id, thresholds: LookMatchFixture.oneScene))
        let proposal = try #require(result.scenes.first?.proposals.first)
        #expect(proposal.adjustments.raw.temperature == 5127)
        #expect(proposal.adjustments.raw.tint == -3)
        #expect(proposal.adjustments.vibrance == look.vibrance)
    }

    /// Found on 2026-10-19: analyses blocked inside Vision on Swift's cooperative threads.
    /// With enough at once, every cooperative thread waited on Vision and nothing ran. The
    /// service must keep its blocking work off that pool. The wait below is a kernel
    /// timeout, so a deadlock fails the test instead of hanging it.
    @Test func manyConcurrentAnalysesFinish() throws {
        let folder = try TempDirectory()
        let url = try LookMatchFixture.write(LookMatchFixture.scene(), to: folder.url.appendingPathComponent("a.png"))
        let request = LookMatchRequest(photos: [
            LookMatchPhoto(id: UUID(), url: url, adjustments: LookMatchFixture.heroLook),
            LookMatchPhoto(id: UUID(), url: url, adjustments: .neutral)
        ], selectedID: nil, thresholds: LookMatchFixture.oneScene)
        let group = DispatchGroup()
        let finished = Collector<Bool>()
        for _ in 0 ..< 24 {
            group.enter()
            Task.detached {
                let result = try? await LookMatchService().analyze(request)
                finished.add(result?.scenes.first?.proposals.count == 1)
                group.leave()
            }
        }
        #expect(group.wait(timeout: .now() + 120) == .success, "Look Match analyses deadlocked")
        #expect(finished.values.count == 24 && finished.values.allSatisfy { $0 })
    }

    @Test(.enabled(if: RawSample.isAvailable))
    func rawTargetsGetTheHerosWhiteBalanceOffsetFromTheirOwnAsShot() async throws {
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

        let result = try await LookMatchService().analyze(LookMatchRequest(
            photos: [hero, target], selectedID: hero.id, thresholds: LookMatchFixture.oneScene))
        let proposal = try #require(result.scenes.first?.proposals.first)
        let expected = LookMatchAnalyzer.carriedWhiteBalance(hero: look.raw, heroAsShot: heroInfo, targetAsShot: targetInfo)
        #expect(proposal.adjustments.raw.temperature == expected.0)
        #expect(proposal.adjustments.raw.tint == expected.1)
        #expect(abs(proposal.adjustments.exposure - look.exposure) <= 1.5)
        #expect(try files.map { try Data(contentsOf: $0) } == before)
    }
}

/// Holds a fake analysis until the test releases it.
private actor AnalysisGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

@MainActor
struct LookMatchStoreTests {
    private struct Shoot {
        var store: EditorStore
        var hero: MediaAsset
        var target: MediaAsset
        var flagged: MediaAsset
        var folder: TempDirectory
    }

    private static var heroLook: PhotoAdjustments {
        var look = PhotoAdjustments.neutral
        look.exposure = 0.3
        look.vibrance = 0.2
        return look
    }

    private static func proposed(exposure: Double) -> PhotoAdjustments {
        var look = heroLook
        look.exposure = exposure
        return look
    }

    /// A store with a hero, a target and a third photo whose proposal is flagged. The injected
    /// analysis waits for `gate` when one is given.
    private func makeShoot(gate: AnalysisGate? = nil) throws -> Shoot {
        let folder = try TempDirectory()
        let assets = try ["hero.jpg", "target.jpg", "flagged.jpg"].map {
            MediaAsset(url: try writeTestJPEG(to: folder.url.appendingPathComponent($0)), pixelWidth: 400, pixelHeight: 300)
        }
        let ids = assets.map(\.id)
        let matched = Self.proposed(exposure: 1.1), lowConfidence = Self.proposed(exposure: -0.9)
        let analyze: @Sendable (LookMatchRequest) async throws -> LookMatchResult = { _ in
            await gate?.wait()
            try Task.checkCancellation()
            return LookMatchResult(scenes: [LookMatchScene(
                index: 1, assetIDs: ids, heroID: ids[0],
                proposals: [
                    LookMatchProposal(targetID: ids[1], heroID: ids[0], adjustments: matched,
                                      confidence: 0.92, isFlagged: false),
                    LookMatchProposal(targetID: ids[2], heroID: ids[0], adjustments: lowConfidence,
                                      confidence: 0.31, isFlagged: true)
                ]
            )])
        }
        let defaults = UserDefaults(suiteName: "pme-lookmatch-\(UUID())")!
        let store = EditorStore(presetRepository: UserPresetRepository(defaults: defaults), lookMatchAnalyzer: analyze)
        store.project.media = assets
        for asset in assets { store.project.adjustmentsByAssetID[asset.id] = .neutral }
        store.project.adjustmentsByAssetID[ids[0]] = Self.heroLook
        store.select(assets[0])
        store.workspace = .agents
        return Shoot(store: store, hero: assets[0], target: assets[1], flagged: assets[2], folder: folder)
    }

    private func run(_ store: EditorStore) async throws {
        let task = try #require(store.startLookMatch())
        await task.value
    }

    @Test func runningLookMatchProducesSelectedAndFlaggedProposals() async throws {
        let shoot = try makeShoot()
        shoot.store.selectedAgentKind = .lookMatching
        shoot.store.runSelectedAgent()
        try await waitUntil { !shoot.store.isRunningLookMatch }
        let report = try #require(shoot.store.latestAgentReport)
        #expect(report.kind == .lookMatching)
        let changes = report.proposedChanges
        #expect(changes.map(\.kind) == [.matchLook, .matchLook])
        #expect(changes.map(\.targetAssetID) == [shoot.target.id, shoot.flagged.id])
        #expect(changes.map(\.isSelected) == [true, false])
        #expect(changes.map(\.sceneIndex) == [1, 1])
        #expect(changes[1].confidence == 0.31)
        #expect(report.findings.contains { $0.title.contains("low-confidence") })
        // Nothing changes until the photographer applies.
        #expect(shoot.store.project.adjustmentsByAssetID[shoot.target.id] == .neutral)
    }

    @Test func finishingDoesNotSwitchAwayFromTheAgentBeingViewed() async throws {
        let gate = AnalysisGate()
        let shoot = try makeShoot(gate: gate)
        let store = shoot.store
        let task = try #require(store.startLookMatch())
        store.selectedAgentKind = .photoCulling
        await gate.open()
        await task.value
        #expect(store.selectedAgentKind == .photoCulling)
        #expect(store.latestAgentReport?.kind == .lookMatching)
    }

    @Test func applyWritesOnlySelectedProposalsAsOneUndoStep() async throws {
        let shoot = try makeShoot()
        let store = shoot.store
        try await run(store)
        let before = store.project.adjustmentsByAssetID
        store.applyLatestAgentChanges()

        #expect(store.project.adjustmentsByAssetID[shoot.target.id] == Self.proposed(exposure: 1.1))
        #expect(store.project.adjustmentsByAssetID[shoot.flagged.id] == .neutral)
        #expect(store.project.adjustmentsByAssetID[shoot.hero.id] == Self.heroLook)
        #expect(store.history[shoot.target.id]?.last?.name == "Look Match")
        #expect(store.latestAgentReport?.proposedChanges.isEmpty == true)

        store.undoPhotoEdit()
        #expect(store.project.adjustmentsByAssetID == before)
        #expect(!store.canUndoPhotoEdit)
    }

    @Test func selectingAFlaggedProposalAppliesBothAndOneUndoRestoresBoth() async throws {
        let shoot = try makeShoot()
        let store = shoot.store
        try await run(store)
        let before = store.project.adjustmentsByAssetID
        let flaggedChange = try #require(store.latestAgentReport?.proposedChanges.first { !$0.isSelected })
        store.setLookMatchChange(flaggedChange.id, selected: true)
        store.applyLatestAgentChanges()
        #expect(store.project.adjustmentsByAssetID[shoot.target.id]?.exposure == 1.1)
        #expect(store.project.adjustmentsByAssetID[shoot.flagged.id]?.exposure == -0.9)
        store.undoPhotoEdit()
        #expect(store.project.adjustmentsByAssetID == before)
    }

    @Test func unselectingEveryProposalAppliesNothing() async throws {
        let shoot = try makeShoot()
        let store = shoot.store
        try await run(store)
        for change in store.latestAgentReport?.proposedChanges ?? [] {
            store.setLookMatchChange(change.id, selected: false)
        }
        let before = store.project.adjustmentsByAssetID
        store.applyLatestAgentChanges()
        #expect(store.project.adjustmentsByAssetID == before)
        #expect(!store.canUndoPhotoEdit)
    }

    @Test func aTargetEditedAfterAnalysisIsSkippedAndReported() async throws {
        let shoot = try makeShoot()
        let store = shoot.store
        try await run(store)
        var manual = PhotoAdjustments.neutral
        manual.saturation = -0.5
        store.project.adjustmentsByAssetID[shoot.target.id] = manual
        store.applyLatestAgentChanges()
        #expect(store.project.adjustmentsByAssetID[shoot.target.id] == manual)
        let report = try #require(store.latestAgentReport)
        #expect(report.findings.contains { $0.title == "Edited since analysis" && $0.assetID == shoot.target.id })
        #expect(report.summary.contains("1 skipped"))
    }

    @Test func resultsArrivingAfterProjectReplacementAreDiscarded() async throws {
        let gate = AnalysisGate()
        let shoot = try makeShoot(gate: gate)
        let store = shoot.store
        let task = try #require(store.startLookMatch())
        #expect(store.isRunningLookMatch)
        store.resetToEmptyProject(named: "Next shoot")
        await gate.open()
        await task.value
        #expect(!store.isRunningLookMatch)
        #expect(store.latestAgentReport == nil)
        #expect(store.lookMatchBaseline == nil)
        #expect(store.project.adjustmentsByAssetID.isEmpty)
    }

    @Test func staleCompletionFromAnOlderRequestIsIgnored() async throws {
        let shoot = try makeShoot()
        let store = shoot.store
        let generation = store.projectGeneration
        store.isRunningLookMatch = true
        store.lookMatchRequestID = UUID()
        store.finishLookMatch(LookMatchResult(scenes: []), request: LookMatchRequest(photos: []),
                              projectID: store.project.id, generation: generation,
                              requestID: UUID(), startedAt: .now)
        #expect(store.latestAgentReport == nil)
        store.cancelLookMatch()
    }

    @Test func cancellationLeavesTheProjectUnchanged() async throws {
        let gate = AnalysisGate()
        let shoot = try makeShoot(gate: gate)
        let store = shoot.store
        let before = store.project
        let task = try #require(store.startLookMatch())
        store.cancelLookMatch()
        await gate.open()
        await task.value
        #expect(!store.isRunningLookMatch)
        #expect(store.latestAgentReport == nil)
        #expect(store.project == before)
        #expect(store.statusMessage == "Look Match canceled")
    }

    @Test func withoutAnEditedHeroNoAnalysisRuns() throws {
        let shoot = try makeShoot()
        let store = shoot.store
        store.project.adjustmentsByAssetID[shoot.hero.id] = .neutral
        #expect(store.startLookMatch() == nil)
        #expect(!store.isRunningLookMatch)
        #expect(store.latestAgentReport?.findings.first?.title == "No edited hero photo")
    }

    @Test func otherAgentsKeepTheirCopyBehavior() throws {
        let shoot = try makeShoot()
        let store = shoot.store
        store.runAgent(.batchEditing)
        let changes = try #require(store.latestAgentReport?.proposedChanges)
        #expect(changes.allSatisfy { $0.kind == .copyPhotoAdjustments && $0.proposedAdjustments == nil })
        store.applyLatestAgentChanges()
        #expect(store.project.adjustmentsByAssetID[shoot.target.id]?.exposure == Self.heroLook.exposure)
    }

    @Test func endToEndAnalysisLeavesOriginalsUntouched() async throws {
        let folder = try TempDirectory()
        let scene = LookMatchFixture.scene()
        let heroURL = try LookMatchFixture.write(scene, to: folder.url.appendingPathComponent("hero.png"))
        let targetURL = try LookMatchFixture.write(LookMatchFixture.darkened(scene, ev: -1),
                                                   to: folder.url.appendingPathComponent("target.png"))
        let originals = try [Data(contentsOf: heroURL), Data(contentsOf: targetURL)]
        let defaults = UserDefaults(suiteName: "pme-lookmatch-\(UUID())")!
        let store = EditorStore(presetRepository: UserPresetRepository(defaults: defaults))
        store.lookMatchThresholds = LookMatchFixture.oneScene
        let hero = MediaAsset(url: heroURL), target = MediaAsset(url: targetURL)
        store.project.media = [hero, target]
        store.project.adjustmentsByAssetID = [hero.id: LookMatchFixture.heroLook, target.id: .neutral]
        let task = try #require(store.startLookMatch())
        await task.value
        let change = try #require(store.latestAgentReport?.proposedChanges.first)
        #expect(change.kind == .matchLook && change.targetAssetID == target.id && change.isSelected)
        store.applyLatestAgentChanges()
        let exposure = try #require(store.project.adjustmentsByAssetID[target.id]?.exposure)
        #expect(abs(exposure - (LookMatchFixture.heroLook.exposure + 1)) <= 0.1)
        // The project saves at the current schema with no Look Match data in it.
        let data = try ProjectDocument().data(for: store.project)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 10)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("confidence") && !json.contains("matchLook"))
        #expect(try [Data(contentsOf: heroURL), Data(contentsOf: targetURL)] == originals)
    }
}

/// Opt-in check on a real shoot, for threshold tuning and the acceptance counts. Set
/// PME_LOOK_MATCH_PROJECT to a disposable .pmedit (its saved edits mark the heroes), or
/// PME_LOOK_MATCH_FOLDER to a folder of photos (the first file gets a sample hero edit and
/// everything is treated as one candidate shoot). PME_LOOK_MATCH_OUTPUT optionally names a
/// text file for the report, and PME_LOOK_MATCH_ONE_SCENE=1 forces one scene for a worst-case
/// timing. Originals are only read; the project is not saved.
struct LookMatchRealShootTests {
    private static let environment = ProcessInfo.processInfo.environment

    private static func peakFootprintMB() -> Double {
        var usage = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0)
            }
        }
        return result == 0 ? Double(usage.ri_lifetime_max_phys_footprint) / 1_048_576 : -1
    }

    @Test(.enabled(if: environment["PME_LOOK_MATCH_PROJECT"] != nil || environment["PME_LOOK_MATCH_FOLDER"] != nil))
    func realShootLookMatchReport() async throws {
        var photos: [LookMatchPhoto] = []
        var names: [UUID: String] = [:]
        if let path = Self.environment["PME_LOOK_MATCH_PROJECT"] {
            let project = try ProjectDocument().load(from: URL(fileURLWithPath: path))
            for asset in project.media where asset.kind == .photo {
                photos.append(LookMatchPhoto(id: asset.id, url: asset.url,
                                             adjustments: project.adjustmentsByAssetID[asset.id] ?? .neutral))
                names[asset.id] = asset.filename
            }
        } else {
            let folder = URL(fileURLWithPath: try #require(Self.environment["PME_LOOK_MATCH_FOLDER"]))
            let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
                .filter { ["RW2", "JPG", "JPEG", "PNG", "DNG"].contains(($0 as NSString).pathExtension.uppercased()) }
                .sorted()
            for (index, file) in files.enumerated() {
                var adjustments = PhotoAdjustments.neutral
                if index == 0 {
                    adjustments.exposure = 0.3
                    adjustments.contrast = 0.1
                    adjustments.vibrance = 0.12
                }
                let id = UUID()
                photos.append(LookMatchPhoto(id: id, url: folder.appendingPathComponent(file), adjustments: adjustments))
                names[id] = file
            }
        }
        try #require(photos.count >= 2)
        if let csv = Self.environment["PME_LOOK_MATCH_SIGNALS"] {
            // Per-photo signals in capture order, with distances to the previous frame and to
            // the first frame of the current default-threshold scene.
            let analyzer = LookMatchAnalyzer()
            let signals = LookMatchScenes.ordered(photos.map { analyzer.sceneSignal(for: $0) })
            var rows = ["file,time,mired,ev,distance_previous,distance_scene_start,new_scene"]
            var sceneStart: SceneSignal?
            var previous: SceneSignal?
            for signal in signals {
                let split = previous.map { LookMatchScenes.startsNewScene($0, signal, thresholds: .default) } ?? true
                if split { sceneStart = signal }
                func text(_ value: Double?) -> String { value.map { String(format: "%.3f", $0) } ?? "" }
                rows.append([names[signal.assetID] ?? "?",
                             signal.captureDate.map { ISO8601DateFormatter().string(from: $0) } ?? "",
                             text(signal.asShotMired), text(signal.exposureValue),
                             text(LookMatchScenes.featureDistance(previous?.featurePrint, signal.featurePrint)),
                             text(LookMatchScenes.featureDistance(sceneStart?.featurePrint, signal.featurePrint)),
                             split ? "1" : "0"].joined(separator: ","))
                previous = signal
            }
            try rows.joined(separator: "\n").write(toFile: csv, atomically: true, encoding: .utf8)
            return
        }
        let hashes = try photos.map { Array(SHA256.hash(data: try Data(contentsOf: $0.url))) }
        // PME_LOOK_MATCH_ONE_SCENE=1 solves every photo against one hero: a worst-case timing.
        let thresholds = Self.environment["PME_LOOK_MATCH_ONE_SCENE"] == "1" ? LookMatchFixture.oneScene : .default
        let footprintBefore = Self.peakFootprintMB()
        // Auto on one photo first: the plan's memory budget is Auto's plus feature-print buffers.
        _ = try await AutoAdjustmentService().analyze(url: photos[0].url, current: .neutral)
        let footprintAuto = Self.peakFootprintMB()
        let start = Date()
        let result = try await LookMatchService().analyze(LookMatchRequest(photos: photos, selectedID: nil,
                                                                            thresholds: thresholds))
        let seconds = Date().timeIntervalSince(start)

        var lines: [String] = []
        let proposals = result.scenes.flatMap(\.proposals)
        let flagged = proposals.filter(\.isFlagged).count
        lines.append(String(format: "%d photos, %d scenes, %d proposals (%d unflagged, %d flagged) in %.1f s (%.2f s/photo)",
                            photos.count, result.scenes.count, proposals.count, proposals.count - flagged, flagged,
                            seconds, seconds / Double(photos.count)))
        lines.append(String(format: "Test-process peak footprint: %.0f MB at start, %.0f MB after one Auto analysis, %.0f MB after Look Match",
                            footprintBefore, footprintAuto, Self.peakFootprintMB()))
        lines.append("Thresholds: \(thresholds)")
        for scene in result.scenes {
            let first = scene.assetIDs.first.flatMap { names[$0] } ?? "?"
            let last = scene.assetIDs.last.flatMap { names[$0] } ?? "?"
            lines.append("")
            lines.append("Scene \(scene.index): \(scene.assetIDs.count) photos, \(first) – \(last)"
                + (scene.splitReasons.isEmpty ? "" : "; new scene because \(scene.splitReasons.joined(separator: ", "))"))
            if let hero = scene.heroID {
                lines.append("  hero \(names[hero] ?? "?")")
            } else {
                lines.append("  NEEDS A HERO; suggested \(scene.suggestedHeroID.flatMap { names[$0] } ?? "?")")
            }
            for id in scene.alreadyEdited { lines.append("  already edited: \(names[id] ?? "?")") }
            for id in scene.unreadable { lines.append("  could not analyze: \(names[id] ?? "?")") }
            for proposal in scene.proposals {
                let raw = proposal.adjustments.raw
                lines.append(String(format: "  %@ %@ confidence %.2f  exposure %+.2f  highlights %+.2f  shadows %+.2f  WB %@",
                                    proposal.isFlagged ? "FLAG" : "ok  ", names[proposal.targetID] ?? "?",
                                    proposal.confidence, proposal.adjustments.exposure, proposal.adjustments.highlights,
                                    proposal.adjustments.shadows,
                                    raw.temperature.map { "\(Int($0)) K / \(Int(raw.tint ?? 0))" } ?? "as shot"))
            }
        }
        if let directory = Self.environment["PME_LOOK_MATCH_RENDER_DIR"] {
            // Contact sheets for a visual check: per scene, the hero first, then each proposal as
            // it would look after Apply, left to right in capture order, 6 per row.
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let context = CIContext()
            let byID = Dictionary(photos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for scene in result.scenes {
                guard let heroID = scene.heroID, let hero = byID[heroID] else { continue }
                var cells: [(UUID, PhotoAdjustments)] = [(heroID, hero.adjustments)]
                cells += scene.proposals.map { ($0.targetID, $0.adjustments) }
                for page in stride(from: 0, to: cells.count, by: 36) {
                    let slice = Array(cells[page ..< min(cells.count, page + 36)])
                    let cell = 300.0, columns = 6
                    let rows = (slice.count + columns - 1) / columns
                    var sheet = CIImage(color: CIColor(red: 0.12, green: 0.12, blue: 0.12))
                        .cropped(to: CGRect(x: 0, y: 0, width: cell * Double(columns), height: cell * Double(rows)))
                    for (index, item) in slice.enumerated() {
                        guard let photo = byID[item.0],
                              let source = PhotoSourceLoader.load(photo.url, maxDimension: cell - 8, raw: item.1.raw)
                        else { continue }
                        let rendered = MediaColorRenderer.render(source, adjustments: item.1, includesGeometry: true)
                        let extent = rendered.extent
                        let scale = (cell - 8) / max(extent.width, extent.height)
                        let x = Double(index % columns) * cell + 4, y = Double(rows - 1 - index / columns) * cell + 4
                        let placed = rendered.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
                            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                            .concatenating(CGAffineTransform(translationX: x, y: y)))
                        sheet = placed.composited(over: sheet)
                    }
                    let name = "scene\(scene.index)-\(page / 36 + 1).jpg"
                    try context.writeJPEGRepresentation(of: sheet, to: URL(fileURLWithPath: directory).appendingPathComponent(name),
                                                        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                    lines.append("Sheet \(name): " + slice.map { names[$0.0] ?? "?" }.joined(separator: " "))
                    context.clearCaches()
                }
            }
        }
        let text = lines.joined(separator: "\n")
        print(text)
        if let output = Self.environment["PME_LOOK_MATCH_OUTPUT"] {
            try text.write(toFile: output, atomically: true, encoding: .utf8)
        }
        #expect(try photos.map { Array(SHA256.hash(data: try Data(contentsOf: $0.url))) } == hashes)
    }
}
