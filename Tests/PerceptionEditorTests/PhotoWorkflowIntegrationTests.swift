import Foundation
import Testing
@testable import PerceptionEditor

private func integratedEdits() -> PhotoAdjustments {
    let stroke = BrushStroke(points: [NormalizedPoint(x: 0.3, y: 0.2)], size: 0.04, feather: 0.5, isErase: true)
    let raster = SubjectMask(png: Data([1, 2, 3, 4]), strokes: [stroke], edgeShift: -0.001,
                             edgeFeather: 0.002, edgeContrast: 0.3)
    var edits = PhotoAdjustments(exposure: 0.3, sharpness: 0.4, rotationQuarterTurns: 1,
                                 cropRect: CropRect(x: 0.1, y: 0.1, width: 0.7, height: 0.8))
    edits.raw.detail = 0.3
    edits.masks = [LocalMask(shape: .subject(raster)), LocalMask(shape: .sky(raster))]
    edits.retouches = [RetouchStroke(kind: .clone, points: [NormalizedPoint(x: 0.4, y: 0.4)],
                                   source: NormalizedPoint(x: 0.7, y: 0.7), size: 0.05, feather: 0.6)]
    return edits
}

struct PhotoWorkflowIntegrationTests {
    @Test func schemaTenEditsRoundTripAndOlderSchemaSixThroughNineRemainReadable() throws {
        let document = ProjectDocument()
        let asset = MediaAsset(url: URL(fileURLWithPath: "/fixture/photo.RW2"))
        var project = EditorProject(name: "Integrated", media: [asset], adjustmentsByAssetID: [asset.id: integratedEdits()])
        #expect(EditorProject.currentSchemaVersion == 10)
        let loaded = try document.project(from: document.data(for: project))
        #expect(loaded.adjustmentsByAssetID == project.adjustmentsByAssetID)
        for version in 6...9 {
            var edits = integratedEdits()
            if version == 6 { edits.retouches = [] }
            if version < 8 { edits.masks = [] }
            else { edits.masks.removeAll { if case .sky = $0.shape { return true }; return false } }
            if version == 8 {
                for index in edits.masks.indices {
                    if var selection = edits.masks[index].shape.rasterSelection {
                        selection.edgeShift = 0; selection.edgeFeather = 0; selection.edgeContrast = 0
                        edits.masks[index].shape.rasterSelection = selection
                    }
                }
            }
            project.adjustmentsByAssetID[asset.id] = edits
            var data = try #require(JSONSerialization.jsonObject(with: document.data(for: project)) as? [String: Any])
            data["schemaVersion"] = version
            let older = try document.project(from: JSONSerialization.data(withJSONObject: data))
            #expect(older.schemaVersion == version)
            #expect(older.media.first?.id == asset.id)
            #expect(older.adjustmentsByAssetID[asset.id] == edits)
            let resaved = try document.project(from: document.data(for: older))
            #expect(resaved.schemaVersion == 10 && resaved.adjustmentsByAssetID[asset.id] == edits)
        }
    }

    @Test func syncKeepsEachPhotosRasterSelectionsRepairsAndGeometry() {
        let destination = integratedEdits()
        var source = integratedEdits()
        source.exposure = 1.1
        source.retouches.removeAll()
        source.masks = [LocalMask(shape: .linear(start: .init(x: 0, y: 0), end: .init(x: 1, y: 1)))]
        let synced = destination.applying(source, groups: Set(AdjustmentGroup.allCases))
        #expect(synced.exposure == source.exposure)
        #expect(synced.retouches == destination.retouches)
        #expect(synced.cropRect == destination.cropRect && synced.rotationQuarterTurns == destination.rotationQuarterTurns)
        #expect(synced.masks.filter { !$0.shape.isGradient } == destination.masks)
        #expect(synced.masks.filter { $0.shape.isGradient }.count == 1)
        #expect(source.lookOnly.retouches.isEmpty && destination.lookOnly.masks.isEmpty)
    }

    @Test func undoBudgetAccountsForRasterBytesCorrectionPointsAndRepairPoints() {
        let id = UUID()
        var edits = integratedEdits()
        let originalCost = edits.estimatedRetainedCost
        var subject = edits.masks[0].shape.rasterSelection!
        subject.png = Data(repeating: 127, count: 100_000)
        subject.strokes[0].points += Array(repeating: NormalizedPoint(x: 0.5, y: 0.5), count: 1000)
        edits.masks[0].shape = .subject(subject)
        edits.retouches[0].points += Array(repeating: NormalizedPoint(x: 0.5, y: 0.5), count: 1000)
        #expect(edits.estimatedRetainedCost >= originalCost + 200_000 - 8 + 64_000)
        var history = PhotoUndoHistory(costLimit: originalCost * 3)
        let recorded = history.record(before: [id: .neutral], after: [id: edits])
        #expect(!recorded)
        #expect(history.undo.isEmpty && history.redo.isEmpty && history.retainedCost == 0)
        // Sky data must carry the same accounting as a subject selection.
        let subjectCost = edits.estimatedRetainedCost
        edits.masks[0].shape = .sky(subject)
        #expect(edits.estimatedRetainedCost == subjectCost)
    }
}

private actor IntegratedAutoGate {
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func analyze() async -> AutoAdjustmentSuggestion {
        started = true
        await withCheckedContinuation { continuation = $0 }
        var suggestion = AutoAdjustmentSuggestion()
        suggestion.basic.exposure = 0.8
        suggestion.rawWhiteBalance = WhiteBalanceReading(temperature: 5100, tint: -5)
        return suggestion
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
struct IntegratedAutoTests {
    private func makeStore(_ temp: TempDirectory, gate: IntegratedAutoGate) throws -> (EditorStore, MediaAsset) {
        let source = try writeTestJPEG(to: temp.url.appendingPathComponent("photo.jpg"))
        let store = EditorStore(autoAdjustmentAnalyzer: { _, _ in await gate.analyze() })
        let asset = MediaAsset(url: source)
        store.project.media = [asset]
        store.project.adjustmentsByAssetID[asset.id] = integratedEdits()
        store.selectedAssetID = asset.id
        store.selectedAssetIDs = [asset.id]
        store.workspace = .photo
        return (store, asset)
    }
    private func waitFor(_ gate: IntegratedAutoGate) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !(await gate.started), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(await gate.started)
    }

    @Test func actualAsyncAutoPreservesAdvancedEditsAndOnlyChangesTheCurrentPhoto() async throws {
        let temp = try TempDirectory(), gate = IntegratedAutoGate()
        let (store, asset) = try makeStore(temp, gate: gate)
        let other = MediaAsset(url: asset.url)
        store.project.media.append(other)
        store.project.adjustmentsByAssetID[other.id] = .neutral
        store.selectedAssetIDs.insert(other.id)
        let original = store.selectedAdjustments
        let task = try #require(store.startAutoAdjustment())
        try await waitFor(gate)
        #expect(!store.canAutoAdjustPhoto && store.startAutoAdjustment() == nil)
        await gate.release(); await task.value
        let applied = store.selectedAdjustments
        #expect(applied.exposure == 0.8 && applied.raw.temperature == 5100)
        #expect(applied.masks == original.masks && applied.retouches == original.retouches)
        #expect(applied.cropRect == original.cropRect && applied.raw.detail == original.raw.detail)
        #expect(store.project.adjustmentsByAssetID[other.id] == .neutral)
        #expect(store.photoUndoHistory.undo.count == 1)
        #expect(store.selectedHistory.map(\.name) == ["Start", "Auto"])
        store.undoPhotoEdit(); #expect(store.selectedAdjustments == original)
        store.redoPhotoEdit(); #expect(store.selectedAdjustments == applied)
        let saved = try ProjectDocument().project(from: ProjectDocument().data(for: store.project))
        #expect(saved.adjustmentsByAssetID[asset.id] == applied)
    }

    @Test func asyncCancellationManualEditRelinkAndSameProjectReopenCannotApplyOldAuto() async throws {
        for action in 0..<4 {
            let temp = try TempDirectory(), gate = IntegratedAutoGate()
            let (store, _) = try makeStore(temp, gate: gate)
            let task = try #require(store.startAutoAdjustment())
            try await waitFor(gate)
            switch action {
            case 0: store.cancelAutoAdjustment(); #expect(task.isCancelled)
            case 1: store.updateAdjustments { $0.exposure = 2 }
            case 2: store.project.media[0].url = temp.url.appendingPathComponent("relinked.jpg")
            default:
                let sameProject = temp.url.appendingPathComponent("same.pmedit")
                try ProjectDocument().save(store.project, to: sameProject)
                try store.loadProject(from: sameProject)
            }
            let before = store.project.adjustmentsByAssetID
            await gate.release(); await task.value
            #expect(store.project.adjustmentsByAssetID == before)
            #expect(!store.isAnalyzingAuto && store.autoAdjustmentTask == nil)
            #expect(!store.selectedHistory.contains { $0.name == "Auto" })
        }
    }

    @Test func aSameIdentityProjectWithANewGenerationRejectsTheOldCompletion() throws {
        let temp = try TempDirectory(), gate = IntegratedAutoGate()
        let (store, asset) = try makeStore(temp, gate: gate)
        let previousGeneration = store.projectGeneration
        let original = store.selectedAdjustments
        store.projectGeneration = UUID()
        store.isAnalyzingAuto = true
        var suggestion = AutoAdjustmentSuggestion()
        suggestion.basic.exposure = 0.9
        store.finishAutoAdjustment(suggestion, assetID: asset.id, sourceURL: asset.url,
                                   projectID: store.project.id, generation: previousGeneration,
                                   requestID: store.autoRequestID, original: original)
        #expect(store.selectedAdjustments == original && !store.isAnalyzingAuto)
    }

    @Test func startingAMaskOrRepairToolCancelsPendingAutoWithoutAddingAnEdit() async throws {
        for repair in [false, true] {
            let temp = try TempDirectory(), gate = IntegratedAutoGate()
            defer { Task { await gate.release() } }
            let (store, _) = try makeStore(temp, gate: gate)
            let task = try #require(store.startAutoAdjustment())
            try await waitFor(gate)
            let before = store.selectedAdjustments
            if repair { store.chooseRetouchTool(.heal) }
            else { store.chooseMaskTool(.brush) }
            #expect(!store.isAnalyzingAuto && task.isCancelled)
            await gate.release(); await task.value
            #expect(store.selectedAdjustments == before)
            #expect(store.photoUndoHistory.undo.isEmpty)
        }
    }
}
