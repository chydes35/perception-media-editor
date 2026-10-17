@preconcurrency import AVFoundation
import Foundation
import Metal
import Testing
@testable import PerceptionEditor

@MainActor
struct LUTWorkflowTests {
    private func makeStore(_ temp: TempDirectory, library: String = "Library") throws -> EditorStore {
        let suite = "pme-lut-tests-\(UUID().uuidString)"
        return EditorStore(
            presetRepository: UserPresetRepository(defaults: UserDefaults(suiteName: suite)!),
            proxyStore: ProxyStore(directory: try temp.subdirectory("Proxy Cache-\(library)"), availableBytes: { _ in 1 << 40 }),
            proxyDefaults: UserDefaults(suiteName: suite)!,
            lutLibrary: LUTLibrary(directory: temp.url.appendingPathComponent(library))
        )
    }

    @Test func importingAddsTheLUTToTheLibraryAndPickers() async throws {
        let temp = try TempDirectory()
        let store = try makeStore(temp)
        let source = try LUTLibraryTests.writeLUT(temp.url.appendingPathComponent("Film Look.cube"))
        let reference = try #require(await store.importLUT(from: source))
        #expect(store.availableLUTs == [reference])
        #expect(LoadedLUTs.shared.lut(reference.contentHash) != nil)

        let bad = temp.url.appendingPathComponent("Broken.cube")
        try "LUT_3D_SIZE 2".write(to: bad, atomically: true, encoding: .utf8)
        #expect(await store.importLUT(from: bad) == nil)
        #expect(store.lastError?.contains("Broken.cube") == true)
    }

    @Test func aSavedProjectCarriesItsLUTsAndReopensWithoutTheLibrary() async throws {
        let temp = try TempDirectory()
        let store = try makeStore(temp)
        let reference = try #require(await store.importLUT(from: try LUTLibraryTests.writeLUT(temp.url.appendingPathComponent("V709.cube"))))
        let video = MediaAsset(url: temp.url.appendingPathComponent("P1.MOV"), kind: .video)
        store.project.media.append(video)
        store.setColorInput(.lut(reference), forAssets: [video.id])
        let shoot = try temp.subdirectory("2026-10-16 Ballgame")
        let projectFile = shoot.appendingPathComponent("Ballgame.pmedit")
        #expect(store.saveProject(to: projectFile))
        let copy = shoot.appendingPathComponent("LUTs").appendingPathComponent(LUTLibrary.projectFileName(for: reference))
        #expect(FileManager.default.fileExists(atPath: copy.path), "Saving puts the LUT next to the project")

        // Another Mac: a different, empty library and nothing in memory.
        LoadedLUTs.shared.remove(reference.contentHash)
        let elsewhere = try makeStore(temp, library: "Other Library")
        try elsewhere.loadProject(from: projectFile)
        try await waitUntil { LoadedLUTs.shared.lut(reference.contentHash) != nil }
        #expect(elsewhere.missingLUTs.isEmpty)
        #expect(elsewhere.project.colorInput(for: video.id) == .lut(reference))
        #expect(elsewhere.resolvedInputLUTs().resolved[video.id] != nil)
    }

    @Test func aMissingLUTIsReportedAndRenderingGoesOn() async throws {
        let temp = try TempDirectory()
        let store = try makeStore(temp)
        let gone = LUTReference(contentHash: LUTLibrary.hash(Data(UUID().uuidString.utf8)), displayName: "Lost Look")
        let video = MediaAsset(url: temp.url.appendingPathComponent("P1.MOV"), kind: .video)
        var project = EditorProject(name: "Old", media: [video])
        project.colorInputByAssetID[video.id] = .lut(gone)
        let file = temp.url.appendingPathComponent("Old.pmedit")
        try ProjectDocument().save(project, to: file)

        try store.loadProject(from: file)
        try await waitUntil { !store.missingLUTs.isEmpty }
        #expect(store.missingLUTs == [gone])
        #expect(store.statusMessage.contains("Lost Look"))
        let (resolved, warnings) = store.resolvedInputLUTs()
        #expect(resolved.isEmpty)
        #expect(warnings.count == 1 && warnings[0].contains("Lost Look"))
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func aSourceColorLUTReachesTheTimeline() async throws {
        let temp = try TempDirectory()
        let store = try makeStore(temp)
        let movie = try await writeColorPatternMovie(to: temp.url.appendingPathComponent("A.MOV"))
        await store.importURLs([movie]).value
        store.proxyStore.cancelAll()
        let asset = try #require(store.project.media.first)
        let reference = try #require(await store.importLUT(from: try LUTLibraryTests.writeLUT(temp.url.appendingPathComponent("Look.cube"))))
        store.setColorInput(.lut(reference), forAssets: [asset.id])
        store.addToTimeline(asset)
        try await waitUntil { store.isTimelinePlayback && store.timelinePlaybackDurationSeconds > 0 }
        #expect(store.videoPlayer?.currentItem?.videoComposition?.customVideoCompositorClass != nil, "Source color needs the compositor")
        #expect(store.timelinePlaybackWarnings.isEmpty)

        store.setColorInput(.automatic, forAssets: [asset.id])
        #expect(store.project.colorInputByAssetID[asset.id] == nil)
        store.proxyStore.cancelAll()
    }

    /// Automatic sends detected V-Log through OCIO; ACES chosen by hand does so for any clip (log
    /// whose metadata was lost); As recorded and LUTs do not.
    @Test func ocioSourceColorFollowsTheChoiceAndTheDetection() throws {
        let temp = try TempDirectory()
        let store = try makeStore(temp)
        func video(_ name: String, log: Bool) -> MediaAsset {
            var asset = MediaAsset(url: temp.url.appendingPathComponent(name), kind: .video)
            asset.sourceColor = SourceColorDescriptor(
                bitDepth: 10, chroma: .yuv422, range: log ? .full : .video, matrix: .rec709,
                transfer: log ? .vLog : .rec709, gamut: log ? .vGamut : .rec709, detectedFrom: .panasonicMetadata
            )
            return asset
        }
        let log = video("P1107158.MOV", log: true), flat = video("P1107159.MOV", log: true)
        let rec709 = video("P1107172.MOV", log: false), untagged = video("P1107173.MOV", log: false)
        let graded = video("P1107174.MOV", log: true)
        store.project.media = [log, flat, rec709, untagged, graded]
        store.setColorInput(.none, forAssets: [flat.id])
        store.setColorInput(.aces, forAssets: [untagged.id])
        store.setColorInput(.lut(LUTReference(contentHash: LUTLibrary.hash(Data("x".utf8)), displayName: "V709")), forAssets: [graded.id])
        #expect(store.resolvedOCIOInputs() == [log.id: .vLogVGamut, untagged.id: .vLogVGamut])
    }

    @Test func theACESChoiceSurvivesSaveAndReopen() throws {
        let temp = try TempDirectory()
        let store = try makeStore(temp)
        let video = MediaAsset(url: temp.url.appendingPathComponent("P1.MOV"), kind: .video)
        store.project.media.append(video)
        store.setColorInput(.aces, forAssets: [video.id])
        let projectFile = try temp.subdirectory("Shoot").appendingPathComponent("Shoot.pmedit")
        #expect(store.saveProject(to: projectFile))
        let reopened = try makeStore(temp, library: "Other Library")
        try reopened.loadProject(from: projectFile)
        #expect(reopened.project.colorInput(for: video.id) == .aces)
    }
}
