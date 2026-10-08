import Foundation
import Testing
import UniformTypeIdentifiers
@testable import PerceptionEditor

struct ExportReliabilityTests {
    @Test func exportingOverTheOriginalIsRejectedWithoutChangingIt() async throws {
        let temp = try TempDirectory()
        let source = try writeTestJPEG(to: temp.url.appendingPathComponent("original.jpg"))
        let original = try Data(contentsOf: source)
        var rejected = false
        do {
            try await PhotoRenderer().export(
                url: source, adjustments: PhotoAdjustments(exposure: 2), to: source, type: .jpeg
            )
        } catch {
            rejected = true
        }
        #expect(rejected, "An export must never overwrite its source")
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func aliasesAndOtherProjectOriginalsAreProtected() async throws {
        let temp = try TempDirectory()
        let source = try writeTestJPEG(to: temp.url.appendingPathComponent("source.jpg"))
        let other = try writeTestJPEG(to: temp.url.appendingPathComponent("other.jpg"))
        let bytes = try Data(contentsOf: other)
        let symbolic = temp.url.appendingPathComponent("symlink.jpg")
        let hard = temp.url.appendingPathComponent("hardlink.jpg")
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: other)
        try FileManager.default.linkItem(at: other, to: hard)

        for destination in [other, symbolic, hard] {
            await #expect(throws: ExportFileError.self) {
                try await PhotoRenderer().export(
                    url: source, adjustments: PhotoAdjustments(exposure: 1),
                    to: destination, type: .jpeg, protectedOriginals: [source, other]
                )
            }
            #expect(try Data(contentsOf: other) == bytes)
        }
        let folderAlias = temp.url.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: folderAlias, withDestinationURL: temp.url)
        #expect(throws: ExportFileError.self) {
            try ExportFileSafety.validate(folderAlias.appendingPathComponent("other.jpg"), protecting: [other])
        }
    }

    @Test func aFailedRenderLeavesThePreviousOutputAndNoTemporaryFile() throws {
        let temp = try TempDirectory()
        let output = temp.url.appendingPathComponent("delivery.jpg")
        let previous = Data("previous completed output".utf8)
        try previous.write(to: output)
        #expect(throws: TestFailure.self) {
            try ExportFileSafety.writeAtomically(to: output, protecting: []) { temporary in
                try Data("partial output".utf8).write(to: temporary)
                throw TestFailure.simulated
            }
        }
        #expect(try Data(contentsOf: output) == previous)
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.url.path) == ["delivery.jpg"])
    }

    @Test func replacingAnExistingOutputPublishesACompleteImage() async throws {
        let temp = try TempDirectory()
        let source = try writeTestJPEG(to: temp.url.appendingPathComponent("source.jpg"))
        let sourceBytes = try Data(contentsOf: source)
        let output = temp.url.appendingPathComponent("delivery.png")
        try Data("old output".utf8).write(to: output)
        try await PhotoRenderer().export(url: source, adjustments: .neutral, to: output, type: .png)
        #expect(PhotoSourceLoader.dimensions(of: output).map { [$0.width, $0.height] } == [400, 300])
        #expect(try Data(contentsOf: source) == sourceBytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.url.path).count == 2)
    }

    @Test func aDestinationRelinkedDuringRenderingIsRechecked() throws {
        let temp = try TempDirectory()
        let source = try writeTestJPEG(to: temp.url.appendingPathComponent("source.jpg"))
        let original = try Data(contentsOf: source)
        let destination = temp.url.appendingPathComponent("delivery.jpg")
        #expect(throws: ExportFileError.self) {
            try ExportFileSafety.writeAtomically(to: destination, protecting: [source]) { temporary in
                try Data("completed output".utf8).write(to: temporary)
                try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: source)
            }
        }
        #expect(try Data(contentsOf: source) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.url.path).count == 2)
    }
}

@MainActor
struct IngestReliabilityTests {
    @Test func cancellingBeforeTheScanStartsDoesNotImportAnything() async throws {
        let temp = try TempDirectory()
        let card = try temp.subdirectory("card")
        try writeTestJPEG(to: card.appendingPathComponent("P100001.JPG"))
        let store = EditorStore()
        store.startIngest(ImportRequest(
            source: card,
            destination: .newShoot(name: "Cancel", date: .now, root: try temp.subdirectory("Shoots")),
            backupRoot: nil
        ))
        store.cancelIngest()
        try await waitUntil(timeout: 30) { !store.ingest.isRunning }
        guard case .finished(let summary) = store.ingest else {
            Issue.record("A stopped import should report cancellation, got \(store.ingest)")
            return
        }
        #expect(summary.wasCancelled)
        #expect(store.project.media.isEmpty)
        #expect(summary.copied == 0)
    }

    @Test func cancellingDuringScanningDoesNotStartTheCopyWorker() async throws {
        let temp = try TempDirectory()
        let card = try temp.subdirectory("card")
        try writeTestJPEG(to: card.appendingPathComponent("P100001.JPG"))
        let gate = ScanGate()
        defer { gate.release() }
        let store = EditorStore(ingestScanner: { gate.scan($0) })
        store.startIngest(ImportRequest(
            source: card,
            destination: .newShoot(name: "Scan", date: .now, root: try temp.subdirectory("Shoots")),
            backupRoot: nil
        ))
        try await waitUntil { gate.hasStarted }
        let task = try #require(store.ingestTask)
        store.cancelIngest()
        gate.release()
        await task.value
        guard case .finished(let summary) = store.ingest else {
            Issue.record("Expected cancellation after scanning")
            return
        }
        #expect(summary.wasCancelled)
        #expect(store.project.media.isEmpty)
        #expect(store.ingestWorker == nil)
    }

    @Test func resettingTheProjectInvalidatesAnInFlightScan() async throws {
        let temp = try TempDirectory()
        let card = try temp.subdirectory("card")
        try writeTestJPEG(to: card.appendingPathComponent("P100001.JPG"))
        let gate = ScanGate()
        defer { gate.release() }
        let store = EditorStore(ingestScanner: { gate.scan($0) })
        store.startIngest(ImportRequest(
            source: card,
            destination: .newShoot(name: "Old", date: .now, root: try temp.subdirectory("Shoots")),
            backupRoot: nil
        ))
        try await waitUntil { gate.hasStarted }
        let task = try #require(store.ingestTask)
        let operation = try #require(store.ingestOperationID)
        let generation = store.projectGeneration
        store.resetToEmptyProject(named: "Replacement")
        let replacementID = store.project.id
        gate.release()
        await task.value
        #expect(!store.acceptsIngest(operation, generation: generation))
        #expect(store.project.id == replacementID)
        #expect(store.project.name == "Replacement")
        #expect(store.project.media.isEmpty)
        #expect(store.ingest == .idle)
    }

    @Test func reopeningTheSameProjectStillInvalidatesOldCallbacks() async throws {
        let temp = try TempDirectory()
        let card = try temp.subdirectory("card")
        try writeTestJPEG(to: card.appendingPathComponent("P100001.JPG"))
        let gate = ScanGate()
        defer { gate.release() }
        let store = EditorStore(ingestScanner: { gate.scan($0) })
        store.startIngest(ImportRequest(
            source: card,
            destination: .newShoot(name: "Same", date: .now, root: try temp.subdirectory("Shoots")),
            backupRoot: nil
        ))
        try await waitUntil { gate.hasStarted }
        let task = try #require(store.ingestTask)
        let projectID = store.project.id
        let generation = store.projectGeneration
        try store.loadProject(from: try #require(store.projectURL))
        gate.release()
        await task.value
        #expect(store.project.id == projectID)
        #expect(store.projectGeneration != generation)
        #expect(store.project.media.isEmpty)
        #expect(store.ingest == .idle)
    }

    @Test func completingACardSavesEveryFileBeforeReportingFinished() async throws {
        let temp = try TempDirectory()
        let card = try temp.subdirectory("card")
        for index in 0 ..< 24 {
            try writeTestJPEG(to: card.appendingPathComponent("P\(index).JPG"), width: 40, height: 30)
        }
        let store = EditorStore()
        store.startIngest(ImportRequest(
            source: card,
            destination: .newShoot(name: "Complete", date: .now, root: try temp.subdirectory("Shoots")),
            backupRoot: nil
        ))
        try await waitUntil(timeout: 30) { !store.ingest.isRunning }
        let saved = try ProjectDocument().load(from: try #require(store.projectURL))
        #expect(saved.media.count == 24)
        #expect(store.project.media.count == 24)
        #expect(Set(saved.media.map(\.url)).count == 24)
        #expect(!store.hasUnsavedChanges)
    }

    @Test func filesAddedInPlaceCannotArriveInAReplacementProject() async throws {
        let temp = try TempDirectory()
        let source = try writeTestJPEG(to: temp.url.appendingPathComponent("source.jpg"))
        let store = EditorStore()
        let task = store.importURLs([source])
        store.resetToEmptyProject(named: "Replacement")
        await task.value
        #expect(store.project.name == "Replacement")
        #expect(store.project.media.isEmpty)
    }

    @Test func aNewImportWaitsForTheOldCopyWorkerToCleanUp() async throws {
        let temp = try TempDirectory()
        let card = try temp.subdirectory("card")
        try writeTestJPEG(to: card.appendingPathComponent("P100001.JPG"))
        let gate = ScanGate()
        defer { gate.release() }
        let scanner = ScanGate()
        scanner.release()
        let store = EditorStore(ingestScanner: { scanner.scan($0) })
        // Hold the retiring copy task after cancellation, as a slow disk cleanup would.
        let oldWorker = Task.detached { () -> Result<IngestResult, Error> in
            gate.waitForRelease()
            return .success(IngestResult(wasCancelled: true))
        }
        store.ingestWorker = oldWorker
        store.resetToEmptyProject(named: "Replacement")
        store.startIngest(ImportRequest(
            source: card,
            destination: .newShoot(name: "New", date: .now, root: try temp.subdirectory("Shoots")),
            backupRoot: nil
        ))
        // Scan completion publishes nil before awaiting the retiring worker.
        try await waitUntil(timeout: 30) {
            scanner.hasStarted && store.ingestScanTask == nil && store.ingestTask != nil
        }
        #expect(store.ingestWorker == nil)
        #expect(store.project.media.isEmpty)
        gate.release()
        let task = try #require(store.ingestTask)
        await task.value
        #expect(store.project.media.count == 1)
        #expect(store.retiringIngestWorker == nil)
    }
}

@MainActor
struct SaveReliabilityTests {
    @Test func aDisconnectedSaveLocationRemainsVisibleUntilRetrySucceeds() throws {
        let temp = try TempDirectory()
        let folder = try temp.subdirectory("mounted")
        let destination = folder.appendingPathComponent("Shoot.pmedit")
        let store = EditorStore()
        #expect(store.saveProject(to: destination))
        let snapshot = store.lastSavedProject
        try FileManager.default.moveItem(at: folder, to: temp.url.appendingPathComponent("disconnected"))
        store.project.name = "Changed name"
        store.autosaveIfNeeded()
        #expect(store.lastSavedProject == snapshot)
        #expect(store.hasUnsavedChanges)
        let error = try #require(store.projectSaveError)
        store.statusMessage = "An unrelated edit"
        #expect(store.projectSaveState == .failed(error))

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(store.saveProject())
        #expect(store.projectSaveError == nil)
        #expect(store.projectSaveState == .saved)
        #expect(try ProjectDocument().load(from: destination).name == "Changed name")
    }

    @Test func saveAsRecoversAFailedProjectAndReplacementClearsOldErrors() throws {
        let temp = try TempDirectory()
        let store = EditorStore()
        store.projectURL = temp.url.appendingPathComponent("missing/Shoot.pmedit")
        store.project.name = "Recovered"
        store.autosaveIfNeeded()
        #expect(store.projectSaveError != nil)
        let recovery = temp.url.appendingPathComponent("Recovered.pmedit")
        #expect(store.saveProject(to: recovery))
        #expect(store.projectURL == recovery)
        #expect(store.projectSaveState == .saved)
        store.project.name = "Pending"
        #expect(store.projectSaveState == .pending)
        store.resetToEmptyProject(named: "New")
        #expect(store.projectSaveError == nil)
        #expect(store.projectSaveState == .unsaved)
    }
}

@MainActor
struct UndoReliabilityTests {
    @Test func aTwoHundredPhotoProjectStoresOnlyChangedAssetsAndCapsUndoSteps() {
        let store = EditorStore()
        let assets = (0 ..< 200).map { MediaAsset(url: URL(fileURLWithPath: "/fixtures/P\($0).RW2")) }
        store.project = EditorProject(
            name: "200 photos", media: assets,
            adjustmentsByAssetID: Dictionary(uniqueKeysWithValues: assets.map { ($0.id, .neutral) })
        )
        store.selectedAssetID = assets[0].id
        for step in 1 ... 120 { store.updateAdjustments { $0.exposure = Double(step) / 100 } }
        #expect(store.photoUndoHistory.undo.count == PhotoUndoHistory.maximumSteps)
        #expect(store.photoUndoHistory.undo.allSatisfy { $0.changes.count == 1 })
        #expect(store.photoUndoHistory.retainedCost <= PhotoUndoHistory.maximumRetainedCost)
        for _ in 0 ..< 100 { store.undoPhotoEdit() }
        #expect(abs(store.selectedAdjustments.exposure - 0.2) < 0.00001)
        #expect(!store.canUndoPhotoEdit)
        for _ in 0 ..< 100 { store.redoPhotoEdit() }
        #expect(store.selectedAdjustments.exposure == 1.2)
        #expect(store.project.adjustmentsByAssetID[assets[199].id] == .neutral)
    }

    @Test func undoDoesNotRestoreRemovedPhotosOrOverwriteUnrelatedChanges() {
        let store = EditorStore()
        let a = MediaAsset(url: URL(fileURLWithPath: "/fixtures/A.jpg"))
        let b = MediaAsset(url: URL(fileURLWithPath: "/fixtures/B.jpg"))
        store.project = EditorProject(name: "Undo", media: [a, b], adjustmentsByAssetID: [a.id: .neutral, b.id: .neutral])
        store.selectedAssetID = a.id
        store.updateAdjustments { $0.exposure = 1 }
        store.project.adjustmentsByAssetID[b.id] = PhotoAdjustments(exposure: 2)
        store.undoPhotoEdit()
        #expect(store.project.adjustmentsByAssetID[b.id]?.exposure == 2)
        store.redoPhotoEdit()
        store.removeFromProject([a.id])
        store.undoPhotoEdit()
        #expect(store.project.adjustmentsByAssetID[a.id] == nil)
        #expect(store.project.media.map(\.id) == [b.id])
    }

    @Test func brushHistoryIsBoundedAcrossTheWholeShoot() {
        let store = EditorStore()
        let asset = MediaAsset(url: URL(fileURLWithPath: "/fixtures/A.jpg"))
        store.project = EditorProject(name: "History", media: [asset], adjustmentsByAssetID: [asset.id: .neutral])
        store.selectedAssetID = asset.id
        let points = Array(repeating: NormalizedPoint(x: 0.5, y: 0.5), count: 20_000)
        for step in 1 ... 50 {
            store.updateAdjustments {
                $0.masks = [LocalMask(shape: .brush(strokes: [BrushStroke(points: points, size: 0.1, feather: 0.5)]))]
                $0.exposure = Double(step) / 100
            }
        }
        let retained = store.history.values.flatMap { $0 }.reduce(0) {
            $0 + $1.adjustments.estimatedRetainedCost + 256
        }
        #expect(retained <= EditorStore.historyCostLimit)
        #expect(store.selectedHistory.last?.adjustments == store.selectedAdjustments)
    }
}

struct UndoBudgetReliabilityTests {
    @Test func undoAndRedoShareACostBudgetAndOversizedEditsBreakTheChain() {
        let id = UUID()
        let neutral = [id: PhotoAdjustments.neutral]
        let edited = [id: PhotoAdjustments(exposure: 1)]
        let cost = PhotoUndoStep(before: neutral, after: edited).retainedCost
        var history = PhotoUndoHistory(costLimit: cost * 2)
        let first = history.record(before: neutral, after: edited)
        let second = history.record(before: edited, after: neutral)
        let third = history.record(before: neutral, after: edited)
        #expect(first && second && third)
        #expect(history.undo.count == 2)
        #expect(history.retainedCost == cost * 2)
        _ = history.undoStep()
        #expect(history.retainedCost == cost * 2)
        #expect(history.undo.count == 1 && history.redo.count == 1)
        var heavy = PhotoAdjustments.neutral
        heavy.masks = [LocalMask(shape: .brush(strokes: [
            BrushStroke(points: Array(repeating: NormalizedPoint(x: 0.5, y: 0.5), count: 1000), size: 0.1, feather: 0.5)
        ]))]
        let oversizedWasRecorded = history.record(before: edited, after: [id: heavy])
        #expect(!oversizedWasRecorded)
        #expect(history.undo.isEmpty && history.redo.isEmpty)
        #expect(history.retainedCost == 0)
    }
}

private enum TestFailure: Error { case simulated }

/// Holds a real scan at a known point so cancellation/replacement checks do not depend on sleeps.
private final class ScanGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var released = false

    var hasStarted: Bool {
        condition.lock()
        defer { condition.unlock() }
        return started
    }

    func scan(_ source: URL) -> [SourceFile] {
        condition.lock()
        started = true
        while !released && !Task.isCancelled {
            _ = condition.wait(until: Date().addingTimeInterval(0.02))
        }
        condition.unlock()
        return IngestService.scan(source)
    }

    func waitForRelease() {
        condition.lock()
        started = true
        while !released { condition.wait() }
        condition.unlock()
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}
