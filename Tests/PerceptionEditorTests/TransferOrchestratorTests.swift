import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import PerceptionEditor

/// A scripted Studio OS. Behaviour is configured per test; calls are recorded.
final class FakeStudioOS: StudioOSAPI, @unchecked Sendable {
    struct State {
        var created: StudioOSCreateTransfer?
        var createCalls = 0
        var uploadURLCalls: [String: Int] = [:]
        var arrived: Set<String> = []
        var putCount: [String: Int] = [:]
        var completed: Set<String> = []
        var inFlight = 0
        var maxInFlight = 0
        // scripts
        var createError: StudioOSError?
        var healthError: StudioOSError?
        var forbidFirstPutFor: Set<String> = []
        var lostAckOnceFor: Set<String> = []
        var rejectCompleteFor: [String: String] = [:]
        var failedPreviewFor: Set<String> = []
        var uploadError: StudioOSError?
        var completeReturnsReady = false
        var gate: AsyncStream<Void>.Continuation?
    }
    let state = Mutex(State())
    var uploadDelay: Duration = .zero

    func health() async throws -> StudioOSHealth {
        try state.withLock { s in if let error = s.healthError { throw error } }
        return StudioOSHealth(status: "ok", api: "ok", storage: "ok")
    }
    func destinations() async throws -> [StudioOSDestination] { [] }

    func createTransfer(_ request: StudioOSCreateTransfer) async throws -> StudioOSRemoteTransfer {
        try state.withLock { s in
            s.createCalls += 1
            if let error = s.createError { throw error }
            s.created = request
        }
        return remote()
    }

    func uploadURL(transferID: String, itemID: String) async throws -> StudioOSUploadTarget {
        state.withLock { $0.uploadURLCalls[itemID, default: 0] += 1 }
        return StudioOSUploadTarget(uploadUrl: "https://storage.test/\(itemID)", contentType: "image/jpeg", contentLength: 1, expiresInSeconds: 3600)
    }

    func upload(file: URL, to target: StudioOSUploadTarget) async throws {
        let item = String(target.uploadUrl.split(separator: "/").last ?? "")
        try state.withLock { s in
            if let error = s.uploadError { throw error }
            if s.forbidFirstPutFor.remove(item) != nil { throw StudioOSError.rejected(status: 403, message: "expired") }
            s.inFlight += 1
            s.maxInFlight = max(s.maxInFlight, s.inFlight)
        }
        defer { state.withLock { $0.inFlight -= 1 } }
        if uploadDelay > .zero { try await Task.sleep(for: uploadDelay) }
        _ = try Data(contentsOf: file)   // the staged file must exist when uploading
        state.withLock { s in
            s.arrived.insert(item)
            s.putCount[item, default: 0] += 1
        }
    }

    func complete(transferID: String, itemID: String) async throws -> StudioOSRemoteItem {
        try state.withLock { s in
            if let message = s.rejectCompleteFor[itemID] {
                throw StudioOSError.rejected(status: 400, message: message)
            }
            guard s.arrived.contains(itemID) else {
                throw StudioOSError.rejected(status: 400, message: "The upload has not arrived yet")
            }
            if s.lostAckOnceFor.remove(itemID) != nil {
                s.completed.insert(itemID)   // the server did the work; only the reply is lost
                throw StudioOSError.unreachable("timed out")
            }
            s.completed.insert(itemID)
        }
        let ready = state.withLock { $0.completeReturnsReady }
        return remote().items.first { $0.itemId == itemID }!.with(status: ready ? .ready : .processing)
    }

    func transferStatus(transferID: String) async throws -> StudioOSRemoteTransfer { remote() }

    private func remote() -> StudioOSRemoteTransfer {
        state.withLock { s in
            let items = (s.created?.items ?? []).map { item -> StudioOSRemoteItem in
                let id = "ri-\(item.clientItemId)"
                let status: StudioOSRemoteStatus =
                    s.failedPreviewFor.contains(id) ? .failed : (s.completed.contains(id) ? .ready : .pending)
                return StudioOSRemoteItem(clientItemId: item.clientItemId, itemId: id, mediaId: "m-\(item.clientItemId)", status: status, publicationState: "draft")
            }
            return StudioOSRemoteTransfer(transferId: "tr-1", galleryId: s.created?.galleryId ?? "", items: items)
        }
    }
}

private extension StudioOSRemoteItem {
    func with(status: StudioOSRemoteStatus) -> StudioOSRemoteItem { var copy = self; copy.status = status; return copy }
}

/// A class, not a struct: `Mutex` is noncopyable, so it must live in a reference type.
final class TransferRenderRecorder: Sendable {
    let calls = Mutex<[String]>([])
    let seenExposure = Mutex<[Double]>([])
    func render() -> @Sendable (TransferItemRecord, URL, TransferRecord) async throws -> Void {
        { item, destination, _ in
            self.calls.withLock { $0.append(item.id) }
            self.seenExposure.withLock { $0.append(item.adjustments.exposure) }
            try Data("jpeg-bytes-\(item.id)".utf8).write(to: destination)
        }
    }
}

private func runtime(
    api: FakeStudioOS, store: TransferQueueStore, recorder: TransferRenderRecorder,
    freeSpace: @escaping @Sendable (URL) -> Int64 = { _ in .max }
) -> TransferRuntime {
    TransferRuntime(
        api: api, store: store, render: recorder.render(), freeSpace: freeSpace,
        onChange: { _ in }, pollInterval: .milliseconds(5), maxUploads: 2, maxPollRounds: 20,
        estimatedBytesPerPhoto: 1000
    )
}

private func makeStore(_ temp: TempDirectory) -> TransferQueueStore {
    TransferQueueStore(fileURL: temp.url.appendingPathComponent("transfers.json"))
}

private func seeded(_ store: TransferQueueStore, _ temp: TempDirectory, items: Int) async throws -> TransferRecord {
    var record = sampleRecord(items: items)
    record.stagingFolderPath = temp.url.appendingPathComponent("staging").path
    try await store.upsert(record)
    return record
}

struct TransferOrchestratorTests {
    @Test func sendsEveryPhotoToReadyAndCleansUpStaging() async throws {
        let temp = try TempDirectory()
        let store = makeStore(temp)
        let api = FakeStudioOS()
        api.uploadDelay = .milliseconds(20)
        let recorder = TransferRenderRecorder()
        let record = try await seeded(store, temp, items: 5)

        await TransferOrchestrator(runtime(api: api, store: store, recorder: recorder)).run(record.id)

        let done = try #require(await store.record(id: record.id))
        #expect(done.status == .completed)
        #expect(done.items.allSatisfy { $0.phase == .ready })
        #expect(done.items.allSatisfy { !FileManager.default.fileExists(atPath: $0.stagedPath ?? "/nonexistent") })
        #expect(recorder.calls.withLock { $0 } == (0..<5).map { "asset-\($0)" })   // one render each, in order
        #expect(api.state.withLock { $0.maxInFlight } <= 2)
        let created = try #require(api.state.withLock { $0.created })
        #expect(created.clientTransferId == record.id)
        #expect(created.items.map(\.position) == [0, 1, 2, 3, 4])
        let expected = Data("jpeg-bytes-asset-0".utf8)
        #expect(created.items[0].sizeBytes == expected.count)
        #expect(created.items[0].sha256 == SHA256.hash(data: expected).map { String(format: "%02x", $0) }.joined())
        #expect(recorder.seenExposure.withLock { $0 }.allSatisfy { $0 == 0.5 })   // renders the snapshot
    }

    @Test func aLostAcknowledgementIsReconciledWithoutUploadingTwice() async throws {
        let temp = try TempDirectory()
        let store = makeStore(temp)
        let api = FakeStudioOS()
        api.state.withLock { $0.lostAckOnceFor = ["ri-asset-1"] }
        let recorder = TransferRenderRecorder()
        let record = try await seeded(store, temp, items: 2)
        let orchestrator = TransferOrchestrator(runtime(api: api, store: store, recorder: recorder))

        await orchestrator.run(record.id)
        let paused = try #require(await store.record(id: record.id))
        #expect(paused.status == .paused)
        #expect(paused.pausedReason?.contains("could not be reached") == true)

        await orchestrator.run(record.id)
        let done = try #require(await store.record(id: record.id))
        #expect(done.status == .completed)
        #expect(api.state.withLock { $0.putCount["ri-asset-1"] } == 1)   // never uploaded a second time
        #expect(recorder.calls.withLock { $0.count } == 2)                 // never re-rendered
    }

    @Test func anExpiredUploadURLIsRenewedOnce() async throws {
        let temp = try TempDirectory()
        let store = makeStore(temp)
        let api = FakeStudioOS()
        api.state.withLock { $0.forbidFirstPutFor = ["ri-asset-0"] }
        let record = try await seeded(store, temp, items: 1)

        await TransferOrchestrator(runtime(api: api, store: store, recorder: TransferRenderRecorder())).run(record.id)

        #expect(try #require(await store.record(id: record.id)).status == .completed)
        #expect(api.state.withLock { $0.uploadURLCalls["ri-asset-0"] } == 2)
    }

    @Test func aRevokedTokenPausesWithRenderedFilesKeptThenResumesWithoutReRendering() async throws {
        let temp = try TempDirectory()
        let file = temp.url.appendingPathComponent("transfers.json")
        let store = TransferQueueStore(fileURL: file)
        let api = FakeStudioOS()
        api.state.withLock { $0.createError = .notPaired }
        let recorder = TransferRenderRecorder()
        let record = try await seeded(store, temp, items: 3)

        await TransferOrchestrator(runtime(api: api, store: store, recorder: recorder)).run(record.id)
        let paused = try #require(await store.record(id: record.id))
        #expect(paused.status == .paused)
        #expect(paused.pausedReason?.contains("not paired") == true)
        #expect(paused.items.allSatisfy { $0.phase == .rendered })
        #expect(paused.items.allSatisfy { FileManager.default.fileExists(atPath: $0.stagedPath ?? "") })

        // "Relaunch": a brand-new store and orchestrator over the same file, after re-pairing.
        api.state.withLock { $0.createError = nil }
        let reopened = TransferQueueStore(fileURL: file)
        await TransferOrchestrator(runtime(api: api, store: reopened, recorder: recorder)).run(record.id)

        #expect(try #require(await reopened.record(id: record.id)).status == .completed)
        #expect(recorder.calls.withLock { $0.count } == 3)   // each photo rendered exactly once overall
    }

    @Test func aRejectedPhotoFailsAloneAndCanBeRetried() async throws {
        let temp = try TempDirectory()
        let store = makeStore(temp)
        let api = FakeStudioOS()
        api.state.withLock { $0.rejectCompleteFor = ["ri-asset-1": "The uploaded file is not a JPEG"] }
        let record = try await seeded(store, temp, items: 3)
        let orchestrator = TransferOrchestrator(runtime(api: api, store: store, recorder: TransferRenderRecorder()))

        await orchestrator.run(record.id)
        let first = try #require(await store.record(id: record.id))
        #expect(first.items.map(\.phase) == [.ready, .failed, .ready])
        #expect(first.items[1].message?.contains("not a JPEG") == true)
        #expect(first.status == .paused)
        #expect(first.pausedReason?.contains("1 photo") == true)

        api.state.withLock { $0.rejectCompleteFor = [:] }
        await orchestrator.retryFailedItems(record.id)
        await orchestrator.run(record.id)
        let second = try #require(await store.record(id: record.id))
        #expect(second.status == .completed)
        #expect(second.items.allSatisfy { $0.phase == .ready })
    }

    @Test func aServerPreviewFailureIsRetryableWithoutUploadingAgain() async throws {
        let temp = try TempDirectory()
        let store = makeStore(temp)
        let api = FakeStudioOS()
        // The server accepts the bytes but its worker fails the preview.
        api.state.withLock { $0.failedPreviewFor = ["ri-asset-0"] }
        let record = try await seeded(store, temp, items: 1)
        let orchestrator = TransferOrchestrator(runtime(api: api, store: store, recorder: TransferRenderRecorder()))

        await orchestrator.run(record.id)
        let failed = try #require(await store.record(id: record.id))
        #expect(failed.items[0].phase == .failed)
        #expect(failed.items[0].stagedPath != nil && FileManager.default.fileExists(atPath: failed.items[0].stagedPath!))

        api.state.withLock { $0.failedPreviewFor = [] }
        await orchestrator.retryFailedItems(record.id)
        await orchestrator.run(record.id)
        #expect(try #require(await store.record(id: record.id)).status == .completed)
        #expect(api.state.withLock { $0.putCount["ri-asset-0"] } == 1)
    }

    @Test func tooLittleDiskSpaceStopsBeforeRendering() async throws {
        let temp = try TempDirectory()
        let store = makeStore(temp)
        let recorder = TransferRenderRecorder()
        let record = try await seeded(store, temp, items: 4)

        await TransferOrchestrator(runtime(api: FakeStudioOS(), store: store, recorder: recorder, freeSpace: { _ in 10 }))
            .run(record.id)

        let paused = try #require(await store.record(id: record.id))
        #expect(paused.status == .paused)
        #expect(paused.pausedReason?.lowercased().contains("space") == true)
        #expect(recorder.calls.withLock { $0.isEmpty })
        #expect(paused.items.allSatisfy { $0.phase == .queued })
    }

    @Test func cancellingKeepsUploadedPhotosAndAllowsResume() async throws {
        let temp = try TempDirectory()
        let store = makeStore(temp)
        let api = FakeStudioOS()
        api.uploadDelay = .milliseconds(150)
        let recorder = TransferRenderRecorder()
        let record = try await seeded(store, temp, items: 6)
        let orchestrator = TransferOrchestrator(runtime(api: api, store: store, recorder: recorder))

        let task = Task { await orchestrator.run(record.id) }
        try await Task.sleep(for: .milliseconds(250))   // let some uploads start
        task.cancel()
        await task.value

        let cancelled = try #require(await store.record(id: record.id))
        #expect(cancelled.status == .cancelled)

        api.uploadDelay = .zero
        await orchestrator.run(record.id)
        let done = try #require(await store.record(id: record.id))
        #expect(done.status == .completed)
        #expect(recorder.calls.withLock { $0.count } == 6)   // no photo rendered twice
        #expect(api.state.withLock { s in s.putCount.values.allSatisfy { $0 == 1 } })
    }

    @Test func concurrentUploadsLeaveNoStagedFilesBehind() async throws {
        // Items become ready straight from `complete` while another upload is in flight, so
        // cleanups interleave. Repeated to make the interleaving likely.
        for _ in 0..<10 {
            let temp = try TempDirectory()
            let store = makeStore(temp)
            let api = FakeStudioOS()
            api.uploadDelay = .milliseconds(2)
            api.state.withLock { $0.completeReturnsReady = true }
            let record = try await seeded(store, temp, items: 6)

            await TransferOrchestrator(runtime(api: api, store: store, recorder: TransferRenderRecorder())).run(record.id)

            #expect(try #require(await store.record(id: record.id)).status == .completed)
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: record.stagingFolderPath)) ?? []
            #expect(leftovers.isEmpty, "staged files left behind: \(leftovers)")
        }
    }

    @Test func readyItemsStillHoldingStagedFilesAreCleanedUpOnResume() async throws {
        // Simulates a crash after the server reported ready but before the staged file was removed.
        let temp = try TempDirectory()
        let store = makeStore(temp)
        let api = FakeStudioOS()
        let recorder = TransferRenderRecorder()
        var record = sampleRecord(items: 2)
        record.stagingFolderPath = temp.url.appendingPathComponent("staging").path
        try FileManager.default.createDirectory(atPath: record.stagingFolderPath, withIntermediateDirectories: true)
        record.remoteTransferID = "tr-1"
        for index in record.items.indices {
            let path = (record.stagingFolderPath as NSString).appendingPathComponent("leftover-\(index).jpg")
            try Data("jpeg".utf8).write(to: URL(fileURLWithPath: path))
            record.items[index].stagedPath = path
            record.items[index].remoteItemID = "ri-asset-\(index)"
            record.items[index].phase = .ready
        }
        try await store.upsert(record)

        await TransferOrchestrator(runtime(api: api, store: store, recorder: recorder)).run(record.id)

        let done = try #require(await store.record(id: record.id))
        #expect(done.status == .completed)
        #expect(done.items.allSatisfy { $0.stagedPath == nil })
        for item in record.items { #expect(!FileManager.default.fileExists(atPath: item.stagedPath!)) }
        #expect(!FileManager.default.fileExists(atPath: record.stagingFolderPath))
        #expect(recorder.calls.withLock { $0.isEmpty })
        #expect(api.state.withLock { $0.createCalls } == 0)
    }

    @Test func aServerOutagePausesTheRunInsteadOfFailingPhotos() async throws {
        let temp = try TempDirectory()
        let store = makeStore(temp)
        let api = FakeStudioOS()
        api.state.withLock { $0.uploadError = .rejected(status: 503, message: "Service Unavailable") }
        let recorder = TransferRenderRecorder()
        let record = try await seeded(store, temp, items: 3)
        let orchestrator = TransferOrchestrator(runtime(api: api, store: store, recorder: recorder))

        await orchestrator.run(record.id)
        let paused = try #require(await store.record(id: record.id))
        #expect(paused.status == .paused)
        #expect(paused.pausedReason?.contains("503") == true)
        #expect(paused.items.allSatisfy { $0.phase == .rendered })
        #expect(paused.items.allSatisfy { FileManager.default.fileExists(atPath: $0.stagedPath ?? "") })

        api.state.withLock { $0.uploadError = nil }
        await orchestrator.run(record.id)
        let done = try #require(await store.record(id: record.id))
        #expect(done.status == .completed)
        #expect(recorder.calls.withLock { $0.count } == 3)   // nothing rendered twice
    }

    @Test func aStagedPathIsClearedOnlyWhenItsFileWasActuallyRemoved() async throws {
        // Deterministic form of the cleanup invariant: one ready item's file can be removed, the
        // other's cannot (its folder is read-only). Only the removed one may lose its path;
        // clearing "every ready item" would orphan the file that is still on disk.
        let temp = try TempDirectory()
        let store = makeStore(temp)
        var record = sampleRecord(items: 2)
        record.stagingFolderPath = temp.url.appendingPathComponent("staging").path
        record.remoteTransferID = "tr-1"
        let locked = temp.url.appendingPathComponent("locked")
        try FileManager.default.createDirectory(atPath: record.stagingFolderPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let removable = (record.stagingFolderPath as NSString).appendingPathComponent("0000-A0.jpg")
        let stuck = locked.appendingPathComponent("0001-A1.jpg").path
        try Data("jpeg".utf8).write(to: URL(fileURLWithPath: removable))
        try Data("jpeg".utf8).write(to: URL(fileURLWithPath: stuck))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        for (index, path) in [removable, stuck].enumerated() {
            record.items[index].stagedPath = path
            record.items[index].remoteItemID = "ri-asset-\(index)"
            record.items[index].phase = .ready
        }
        try await store.upsert(record)

        await TransferOrchestrator(runtime(api: FakeStudioOS(), store: store, recorder: TransferRenderRecorder())).run(record.id)

        let done = try #require(await store.record(id: record.id))
        #expect(!FileManager.default.fileExists(atPath: removable))
        #expect(done.items[0].stagedPath == nil)
        #expect(FileManager.default.fileExists(atPath: stuck))
        #expect(done.items[1].stagedPath == stuck)   // still tracked, so a later run can remove it
    }
}
