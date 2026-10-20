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
        let pngs = try await service.maskPNGs(photoID: id, points: [SegmentationPoint(x: 0.5, y: 0.5, include: true)])
        #expect(pngs.count == 3)
        let sizes = try pngs.map { try #require(CIImage(data: $0)).extent }
        #expect(sizes.allSatisfy { $0.width / $0.height == 4.0 / 3.0 })
        #expect(sizes.allSatisfy { $0.width <= ClickSelectionService.workingDimension })
    }

    @Test func masksForAPhotoThatWasNotPreparedAreRefused() async throws {
        let service = ClickSelectionService(segmenter: FakeSegmenter())
        await #expect(throws: SegmentationError.notPrepared) {
            try await service.maskPNGs(photoID: UUID(), points: [SegmentationPoint(x: 0.5, y: 0.5, include: true)])
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
        try await waitUntil { store.clickMaskPNGs.count == 3 }
        #expect(store.clickPoints.count == 1)
        store.setClickGranularity(2)
        #expect(store.clickGranularity == 2)
        let before = store.project.adjustmentsByAssetID[asset.id]?.masks.count ?? 0
        store.acceptClickSelection()
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
        #expect(store.clickMaskPNGs.isEmpty)
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
        #expect(store.clickMaskPNGs.isEmpty)
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
