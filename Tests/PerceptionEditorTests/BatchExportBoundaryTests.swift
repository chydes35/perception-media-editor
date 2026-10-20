import Foundation
import Testing
@testable import PerceptionEditor

private enum BatchBoundaryFixtureError: Error { case timedOut, simulatedFailure }

/// Pauses after a complete disposable JPEG is written to the production publisher's
/// temporary file. The wait is on the exporter actor, never the main actor.
private final class BatchPublicationGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var open = false
    private var paused = false
    private var calls: [UUID] = []
    let pauseAt: Int

    init(pauseAt: Int = 0) { self.pauseAt = pauseAt }
    var hasPaused: Bool { condition.lock(); defer { condition.unlock() }; return paused }
    var startedIDs: [UUID] { condition.lock(); defer { condition.unlock() }; return calls }
    func record(_ id: UUID) -> Bool {
        condition.lock(); defer { condition.unlock() }
        calls.append(id)
        return calls.count - 1 == pauseAt
    }
    func wait() throws {
        condition.lock(); defer { condition.unlock() }
        paused = true
        let deadline = Date().addingTimeInterval(TestDeadline.event)
        while !open {
            guard condition.wait(until: deadline) || open else { throw BatchBoundaryFixtureError.timedOut }
        }
    }
    func release() { condition.lock(); open = true; condition.broadcast(); condition.unlock() }
}

private actor ControlledBatchExporter {
    let gate: BatchPublicationGate
    let failsAfterPause: Bool
    let returnsLateSuccess: Bool
    init(gate: BatchPublicationGate, failsAfterPause: Bool = false, returnsLateSuccess: Bool = false) {
        self.gate = gate
        self.failsAfterPause = failsAfterPause
        self.returnsLateSuccess = returnsLateSuccess
    }
    func export(_ item: BatchExportItem, to destination: URL, originals: [URL]) throws {
        let pause = gate.record(item.id)
        let bytes = try Data(contentsOf: item.source)
        do {
            try ExportFileSafety.writeAtomically(to: destination, protecting: originals, replaceExisting: false) { temporary in
                try bytes.write(to: temporary)
                if pause {
                    try gate.wait()
                    if failsAfterPause { throw BatchBoundaryFixtureError.simulatedFailure }
                }
            }
        } catch is CancellationError where returnsLateSuccess {
            // Model a noncooperative framework completion; the real publisher already
            // cleaned the temporary file and the store must reject the stale success.
            return
        }
    }
}

@MainActor
@Suite(.serialized)
struct BatchExportBoundaryTests {
    private func photos(in temp: TempDirectory) throws -> [MediaAsset] {
        try (0..<3).map { number in
            // Match imported metadata so reopen cannot launch an unrelated dimension backfill.
            MediaAsset(url: try writeTestJPEG(to: temp.url.appendingPathComponent("photo\(number).jpg")),
                       pixelWidth: 400, pixelHeight: 300)
        }
    }
    private func store(photos: [MediaAsset], exporter: ControlledBatchExporter? = nil) -> EditorStore {
        let store: EditorStore
        if let exporter {
            store = EditorStore(batchPhotoExporter: { item, destination, _, originals in
                try await exporter.export(item, to: destination, originals: originals)
            })
        } else { store = EditorStore() }
        store.project.media = photos
        store.selectedAssetID = photos.first?.id
        store.selectedAssetIDs = Set(photos.map(\.id))
        return store
    }
    private func waitFor(_ gate: BatchPublicationGate) async throws {
        let deadline = Date().addingTimeInterval(TestDeadline.event)
        while !gate.hasPaused, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(gate.hasPaused)
    }
    private func names(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    @Test(arguments: [0, 1])
    func stoppingDuringPublicationLeavesOnlyPreviouslyCompletedFiles(pauseAt: Int) async throws {
        let temp = try TempDirectory(), gate = BatchPublicationGate(pauseAt: pauseAt)
        defer { gate.release() }
        let assets = try photos(in: temp)
        let originals = try assets.map { try Data(contentsOf: $0.url) }
        let output = try temp.subdirectory("delivery")
        let store = store(photos: assets, exporter: ControlledBatchExporter(gate: gate))
        let task = try store.startBatchExport(to: output, recipe: BatchExportRecipe())
        try await waitFor(gate)
        #expect(store.isExporting && store.batchExportState.completed == pauseAt)
        #expect(store.batchExportState.currentFilename == assets[pauseAt].filename)
        #expect(try names(in: output).filter { $0.hasPrefix(".pme-export-") }.count == 1)
        store.cancelBatchExport()
        #expect(task.isCancelled)
        gate.release()
        await task.value
        #expect(store.batchExportState.wasCancelled && !store.isExporting && store.batchExportTask == nil)
        #expect(store.batchExportState.completed == pauseAt && store.batchExportState.currentFilename == nil)
        #expect(store.batchExportState.results.map(\.id) == Array(assets.prefix(pauseAt)).map(\.id))
        #expect(gate.startedIDs == Array(assets.prefix(pauseAt + 1)).map(\.id))
        #expect(try names(in: output) == (0..<pauseAt).map { "photo\($0)_edited.jpg" })
        for index in assets.indices { #expect(try Data(contentsOf: assets[index].url) == originals[index]) }
        for result in store.batchExportState.results {
            #expect(result.succeeded)
            #expect(PhotoSourceLoader.dimensions(of: try #require(result.output)) != nil)
        }
    }

    @Test func anUnreadableFileIsReportedAndTheRealRendererContinuesWithLaterFiles() async throws {
        let temp = try TempDirectory()
        let assets = try photos(in: temp)
        let original = try Data(contentsOf: assets[2].url)
        try FileManager.default.removeItem(at: assets[1].url) // Disposable missing-source fixture.
        let output = try temp.subdirectory("delivery")
        let store = store(photos: assets)
        let task = try store.startBatchExport(to: output, recipe: BatchExportRecipe(longEdgePixels: 200))
        await task.value
        #expect(store.batchExportState.completed == 3 && !store.batchExportState.wasCancelled)
        #expect(store.batchExportState.results.map(\.id) == assets.map(\.id))
        #expect(store.batchExportState.results.map(\.succeeded) == [true, false, true])
        #expect(store.batchExportState.results[1].error != nil && store.batchExportState.results[1].output == nil)
        #expect(try names(in: output) == ["photo0_edited.jpg", "photo2_edited.jpg"])
        for result in store.batchExportState.results where result.succeeded {
            #expect(PhotoSourceLoader.dimensions(of: try #require(result.output)).map { [$0.width, $0.height] } == [200, 150])
        }
        #expect(try Data(contentsOf: assets[2].url) == original)
        #expect(!store.isExporting && store.batchExportTask == nil)
    }

    @Test(arguments: [false, true])
    func replacingOrReopeningAProjectRejectsLateSuccessAndFailure(failsAfterPause: Bool) async throws {
        let temp = try TempDirectory(), gate = BatchPublicationGate()
        defer { gate.release() }
        let assets = try photos(in: temp)
        let output = try temp.subdirectory("old-delivery")
        let store = store(photos: assets, exporter: ControlledBatchExporter(
            gate: gate, failsAfterPause: failsAfterPause, returnsLateSuccess: !failsAfterPause
        ))
        let oldIdentity = store.project.id
        let oldGeneration = store.projectGeneration
        let task = try store.startBatchExport(to: output, recipe: BatchExportRecipe())
        try await waitFor(gate)
        if failsAfterPause { store.resetToEmptyProject(named: "New project") }
        else {
            let saved = temp.url.appendingPathComponent("same.pmedit")
            try ProjectDocument().save(store.project, to: saved)
            try store.loadProject(from: saved)
            #expect(store.project.id == oldIdentity)
        }
        #expect(store.projectGeneration != oldGeneration && task.isCancelled)
        store.statusMessage = "Current project status"
        store.lastError = "Current project error"
        let project = store.project
        gate.release()
        await task.value
        #expect(store.project == project)
        #expect(store.statusMessage == "Current project status" && store.lastError == "Current project error")
        #expect(store.batchExportState.total == 0 && store.batchExportState.completed == 0)
        #expect(store.batchExportState.results.isEmpty && store.batchExportState.currentFilename == nil)
        #expect(!store.isExporting && store.batchExportTask == nil)
        #expect(gate.startedIDs == [assets[0].id])
        #expect(try names(in: output).isEmpty)
    }

    @Test func aLateOldQueueCannotClearANewQueuesHandleOrProgress() async throws {
        let temp = try TempDirectory(), gate = BatchPublicationGate(), newGate = BatchPublicationGate()
        defer { gate.release(); newGate.release() }
        let assets = try photos(in: temp)
        let oldOutput = try temp.subdirectory("old-delivery")
        let newOutput = try temp.subdirectory("new-delivery")
        let oldExporter = ControlledBatchExporter(gate: gate, returnsLateSuccess: true)
        let newExporter = ControlledBatchExporter(gate: newGate)
        let store = EditorStore(batchPhotoExporter: { item, destination, _, originals in
            let exporter = destination.deletingLastPathComponent() == oldOutput ? oldExporter : newExporter
            try await exporter.export(item, to: destination, originals: originals)
        })
        store.project.media = assets
        store.selectedAssetIDs = Set(assets.map(\.id))
        let oldTask = try store.startBatchExport(to: oldOutput, recipe: BatchExportRecipe())
        try await waitFor(gate)
        store.resetToEmptyProject(named: "Replacement")
        store.project.media = [assets[2]]
        store.selectedAssetID = assets[2].id
        store.selectedAssetIDs = [assets[2].id]
        let newTask = try store.startBatchExport(to: newOutput, recipe: BatchExportRecipe())
        try await waitFor(newGate)
        let newStatus = store.statusMessage
        gate.release()
        await oldTask.value
        #expect(store.batchExportTask != nil && store.isExporting && !newTask.isCancelled)
        #expect(store.batchExportState.total == 1 && store.batchExportState.completed == 0)
        #expect(store.batchExportState.currentFilename == assets[2].filename && store.batchExportState.results.isEmpty)
        #expect(store.statusMessage == newStatus && !store.batchExportState.wasCancelled)
        newGate.release()
        await newTask.value
        #expect(store.batchExportState.total == 1 && store.batchExportState.completed == 1)
        #expect(store.batchExportState.results.map(\.id) == [assets[2].id])
        #expect(!store.batchExportState.wasCancelled && !store.isExporting && store.batchExportTask == nil)
        #expect(try names(in: oldOutput).isEmpty)
        #expect(try names(in: newOutput) == ["photo2_edited.jpg"])
    }
}
