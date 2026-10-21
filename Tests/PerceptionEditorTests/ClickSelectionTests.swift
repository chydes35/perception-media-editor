import CoreImage
import Foundation
import Testing
@testable import PerceptionEditor

@MainActor
struct ClickSelectionTests {
    private func photoStore(_ temp: TempDirectory) throws -> (EditorStore, MediaAsset) {
        let url = try writeTestJPEG(to: temp.url.appendingPathComponent("P1000.jpg"), width: 400, height: 300)
        let suite = "pme-click-\(UUID().uuidString)"
        let store = EditorStore(presetRepository: UserPresetRepository(defaults: UserDefaults(suiteName: suite)!))
        let asset = MediaAsset(url: url, kind: .photo, pixelWidth: 400, pixelHeight: 300)
        store.project.media = [asset]
        store.project.adjustmentsByAssetID[asset.id] = .neutral
        store.select(asset)
        store.workspace = .photo
        store.clickSelectionService = ClickSelectionService(segmenter: FakeSegmenter())
        return (store, asset)
    }

    @Test func serviceReturnsMasksTheShapeOfThePhotoSmallestFirst() async throws {
        let temp = try TempDirectory()
        let url = try writeTestJPEG(to: temp.url.appendingPathComponent("a.jpg"), width: 400, height: 300)
        let service = ClickSelectionService(segmenter: FakeSegmenter())
        let id = UUID()
        try await service.prepare(url: url, photoID: id)
        let masks = try await service.masks(photoID: id, points: [SegmentationPoint(x: 0.5, y: 0.5, include: true)])
        let pngs = masks.map(\.png)
        #expect(pngs.count == 3)
        let sizes = try pngs.map { try #require(CIImage(data: $0)).extent }
        #expect(sizes.allSatisfy { $0.width / $0.height == 4.0 / 3.0 })
        #expect(sizes.allSatisfy { $0.width <= ClickSelectionService.workingDimension })
    }

    @Test func theFirstMaskShownIsTheMostConfidentOneThatIsNotMostOfThePhoto() {
        func mask(_ score: Float, _ coverage: Double) -> ClickMask { ClickMask(png: Data(), score: score, coverage: coverage) }
        #expect(ClickMask.defaultIndex(in: [mask(0.4, 0.02), mask(0.9, 0.10), mask(0.95, 0.60)]) == 1)
        #expect(ClickMask.defaultIndex(in: [mask(0.5, 0.5), mask(0.9, 0.4), mask(0.3, 0.9)]) == 1)
        #expect(ClickMask.defaultIndex(in: [mask(0.5, 0.05)]) == 0)
        // The dog case: object 0.731 and whole 0.754 are nearly tied, so the smaller wins.
        #expect(ClickMask.defaultIndex(in: [mask(0.36, 0.04), mask(0.731, 0.11), mask(0.754, 0.14)]) == 1)
    }

    @Test func masksForAPhotoThatWasNotPreparedAreRefused() async throws {
        let service = ClickSelectionService(segmenter: FakeSegmenter())
        await #expect(throws: SegmentationError.notPrepared) {
            try await service.masks(photoID: UUID(), points: [SegmentationPoint(x: 0.5, y: 0.5, include: true)])
        }
    }

    @Test func modelsAreReleasedAfterAQuietPeriod() async throws {
        let temp = try TempDirectory()
        let url = try writeTestJPEG(to: temp.url.appendingPathComponent("a.jpg"))
        let service = ClickSelectionService(segmenter: FakeSegmenter(), idleSeconds: 0.2)
        try await service.prepare(url: url, photoID: UUID())
        #expect(await service.isLoaded)
        try await waitUntilAsync { await !service.isLoaded }
    }

    @Test func aClickShowsCandidatesAndAcceptingAddsOneSubjectMask() async throws {
        let temp = try TempDirectory()
        let (store, asset) = try photoStore(temp)
        store.startClickSelection()
        #expect(store.isClickSelecting)
        try await waitUntil { !store.isPreparingClickSelection }
        store.clickSelect(at: NormalizedPoint(x: 0.5, y: 0.5), include: true)
        try await waitUntil { store.clickMasks.count == 3 }
        #expect(store.clickPoints.count == 1)
        store.setClickGranularity(2)
        #expect(store.clickGranularity == 2)
        let before = store.project.adjustmentsByAssetID[asset.id]?.masks.count ?? 0
        store.acceptClickSelection()
        try await waitUntil { !store.isClickSelecting }
        let masks = try #require(store.project.adjustmentsByAssetID[asset.id]?.masks)
        #expect(masks.count == before + 1)
        #expect(masks.last?.shape.rasterSelection != nil)
        #expect(!store.isClickSelecting)
    }

    @Test func undoRemovesTheLastClickAndClearsTheSelectionWhenNoneRemain() async throws {
        let temp = try TempDirectory()
        let (store, _) = try photoStore(temp)
        store.startClickSelection()
        try await waitUntil { !store.isPreparingClickSelection }
        store.clickSelect(at: NormalizedPoint(x: 0.3, y: 0.3), include: true)
        store.clickSelect(at: NormalizedPoint(x: 0.6, y: 0.6), include: false)
        #expect(store.clickPoints.map(\.include) == [true, false])
        store.undoClickPoint()
        #expect(store.clickPoints.count == 1)
        store.undoClickPoint()
        #expect(store.clickPoints.isEmpty)
        #expect(store.clickMasks.isEmpty)
        store.cancelClickSelection()
    }

    @Test func cancelDiscardsEverythingAndLateResultsAreIgnored() async throws {
        let temp = try TempDirectory()
        let (store, asset) = try photoStore(temp)
        store.startClickSelection()
        try await waitUntil { !store.isPreparingClickSelection }
        store.clickSelect(at: NormalizedPoint(x: 0.5, y: 0.5), include: true)
        store.cancelClickSelection()
        try await Task.sleep(for: .milliseconds(300))
        #expect(!store.isClickSelecting)
        #expect(store.clickMasks.isEmpty)
        #expect(store.clickPoints.isEmpty)
        #expect((store.project.adjustmentsByAssetID[asset.id]?.masks.count ?? 0) == 0)
    }
}

private nonisolated func waitUntilAsync(timeout: Duration = TestDeadline.eventDuration, _ condition: @Sendable () async -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while await !condition() {
        guard clock.now < deadline else { Issue.record("Condition not met within \(timeout)"); return }
        try await Task.sleep(for: .milliseconds(20))
    }
}

/// Opt-in on a real photo and the real model. `PM_SAM_MODELS=<folder> PM_SAM_PHOTO=<file> PM_SAM_OUT=<folder>`
/// writes each case's masks (part, object, whole) as PNGs and prints timings and peak memory.
struct ClickSelectionProbe {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PM_SAM_PHOTO"] != nil
                   && ProcessInfo.processInfo.environment["PM_SAM_MODELS"] != nil))
    func realPhotoRealModel() async throws {
        let env = ProcessInfo.processInfo.environment
        let photo = URL(fileURLWithPath: try #require(env["PM_SAM_PHOTO"]))
        let models = URL(fileURLWithPath: try #require(env["PM_SAM_MODELS"]))
        let out = env["PM_SAM_OUT"].map { URL(fileURLWithPath: $0) }
        // "name:x,y[:x,y-:include...]" cases, separated by spaces; a trailing "-" on a point means exclude.
        let cases = (env["PM_SAM_CASES"] ?? "baby:0.585,0.57").split(separator: " ").map(String.init)
        let service = ClickSelectionService(segmenter: SAM2Segmenter(directory: models))
        let id = UUID()
        let clock = ContinuousClock()
        var start = clock.now
        try await service.prepare(url: photo, photoID: id)
        print("PROBE prepare \(clock.now - start), peak \(Self.peakMegabytes()) MB")
        for item in cases {
            let parts = item.split(separator: ":").map(String.init)
            let points = parts.dropFirst().map { token -> SegmentationPoint in
                let exclude = token.hasSuffix("-")
                let numbers = token.replacingOccurrences(of: "-", with: "").split(separator: ",").compactMap { Double($0) }
                return SegmentationPoint(x: numbers[0], y: numbers[1], include: !exclude)
            }
            start = clock.now
            let masks = try await service.masks(photoID: id, points: points)
            print("PROBE \(parts[0]) \(clock.now - start), peak \(Self.peakMegabytes()) MB")
            let chosen = ClickMask.defaultIndex(in: masks)
            start = clock.now
            let refined = await service.refinedPNG(photoID: id, png: masks[chosen].png)
            print("PROBE \(parts[0]) default mask \(chosen), refine \(clock.now - start)")
            try out.map { try refined.write(to: $0.appendingPathComponent("\(parts[0])-refined.png")) }
            for (index, mask) in masks.enumerated() {
                print("PROBE   \(parts[0])-\(index) score \(mask.score) covers \(Int(mask.coverage * 100))%")
                try out.map { try mask.png.write(to: $0.appendingPathComponent("\(parts[0])-\(index).png")) }
            }
        }
        await service.unload()
    }

    private static func peakMegabytes() -> Int {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Int(usage.ru_maxrss) / 1_048_576
    }
}
