import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import PerceptionEditor

// Opt-in checks against a REAL Studio OS API. Skipped unless these are set:
//   PME_STUDIOOS_LIVE_URL      e.g. http://localhost:3001  (a throwaway/test database only)
//   PME_STUDIOOS_LIVE_TOKEN    a valid device token ("pme_...")
//   PME_STUDIOOS_LIVE_GALLERY  id of a gallery owned by that token's owner
// The revoked-token test additionally needs PME_STUDIOOS_LIVE_REVOKED_TOKEN (a token already
// revoked on the server). The token is never put in an assertion message or log.

private enum Live {
    static let env = ProcessInfo.processInfo.environment
    static var enabled: Bool {
        ["PME_STUDIOOS_LIVE_URL", "PME_STUDIOOS_LIVE_TOKEN", "PME_STUDIOOS_LIVE_GALLERY"]
            .allSatisfy { !(env[$0] ?? "").isEmpty }
    }
    static var revokedEnabled: Bool { enabled && !(env["PME_STUDIOOS_LIVE_REVOKED_TOKEN"] ?? "").isEmpty }

    static func connection(token: String? = nil) throws -> StudioOSConnection {
        try StudioOSPairing.validate(
            server: env["PME_STUDIOOS_LIVE_URL"] ?? "", web: nil,
            token: token ?? env["PME_STUDIOOS_LIVE_TOKEN"] ?? ""
        )
    }
    static var galleryID: String { env["PME_STUDIOOS_LIVE_GALLERY"] ?? "" }
}

/// The real client, with a pause before each upload so a cancel can land mid-batch.
private struct SlowUploadAPI: StudioOSAPI {
    let base: StudioOSClient
    let delay: Duration
    func health() async throws -> StudioOSHealth { try await base.health() }
    func destinations() async throws -> [StudioOSDestination] { try await base.destinations() }
    func createTransfer(_ request: StudioOSCreateTransfer) async throws -> StudioOSRemoteTransfer {
        try await base.createTransfer(request)
    }
    func uploadURL(transferID: String, itemID: String) async throws -> StudioOSUploadTarget {
        try await base.uploadURL(transferID: transferID, itemID: itemID)
    }
    func upload(file: URL, to target: StudioOSUploadTarget) async throws {
        try await Task.sleep(for: delay)
        try await base.upload(file: file, to: target)
    }
    func complete(transferID: String, itemID: String) async throws -> StudioOSRemoteItem {
        try await base.complete(transferID: transferID, itemID: itemID)
    }
    func transferStatus(transferID: String) async throws -> StudioOSRemoteTransfer {
        try await base.transferStatus(transferID: transferID)
    }
}

private final class RenderCounter: Sendable {
    let counts = Mutex<[String: Int]>([:])
    let renderDelay: Duration
    init(renderDelay: Duration = .zero) { self.renderDelay = renderDelay }

    /// Small valid JPEGs whose dimensions vary per item, instead of RAW rendering.
    func render() -> @Sendable (TransferItemRecord, URL, TransferRecord) async throws -> Void {
        { item, destination, _ in
            self.counts.withLock { $0[item.id, default: 0] += 1 }
            if self.renderDelay > .zero { try await Task.sleep(for: self.renderDelay) }
            try writeTestJPEG(to: destination, width: 320 + item.position * 8, height: 240 + item.position * 4)
        }
    }
    var total: Int { counts.withLock { $0.values.reduce(0, +) } }
}

private func liveRecord(_ temp: TempDirectory, items: Int, id: String = "pme-live-\(UUID().uuidString.lowercased())") throws -> TransferRecord {
    var record = sampleRecord(id: id, items: items)
    record.serverURL = try Live.connection().serverURL
    record.webURL = nil
    record.galleryID = Live.galleryID
    record.stagingFolderPath = temp.url.appendingPathComponent("staging-\(id)").path
    return record
}

private func liveRuntime(
    api: any StudioOSAPI, store: TransferQueueStore, counter: RenderCounter
) -> TransferRuntime {
    TransferRuntime(
        api: api, store: store, render: counter.render(),
        pollInterval: .milliseconds(500), maxUploads: 2, maxPollRounds: 120,
        estimatedBytesPerPhoto: 100_000
    )
}

@Suite(.serialized, .enabled(if: Live.enabled))
struct StudioOSLiveServerTests {
    private func client() throws -> StudioOSClient { StudioOSClient(connection: try Live.connection()) }

    @Test func fivePhotosArriveAsReadyDraftsAndStagingIsCleaned() async throws {
        let temp = try TempDirectory()
        let store = TransferQueueStore(fileURL: temp.url.appendingPathComponent("transfers.json"))
        let counter = RenderCounter()
        let record = try liveRecord(temp, items: 5)
        try await store.upsert(record)

        await TransferOrchestrator(liveRuntime(api: try client(), store: store, counter: counter)).run(record.id)

        let done = try #require(await store.record(id: record.id))
        #expect(done.status == .completed, "paused reason: \(done.pausedReason ?? "none")")
        #expect(done.items.allSatisfy { $0.phase == .ready })
        #expect(!FileManager.default.fileExists(atPath: record.stagingFolderPath))
        #expect(counter.total == 5)

        let remote = try await client().transferStatus(transferID: try #require(done.remoteTransferID))
        #expect(remote.items.count == 5)
        #expect(remote.items.allSatisfy { $0.status == .ready && $0.publicationState == "draft" })
        #expect(Set(remote.items.map(\.clientItemId)) == Set(record.items.map(\.id)))
    }

    @Test func cancelMidUploadThenResumeFromANewStoreAndOrchestratorFinishesExactlyOnce() async throws {
        let temp = try TempDirectory()
        let file = temp.url.appendingPathComponent("transfers.json")
        let counter = RenderCounter(renderDelay: .milliseconds(20))
        let record = try liveRecord(temp, items: 8)
        let firstStore = TransferQueueStore(fileURL: file)
        try await firstStore.upsert(record)

        let slow = SlowUploadAPI(base: try client(), delay: .milliseconds(400))
        let orchestrator = TransferOrchestrator(liveRuntime(api: slow, store: firstStore, counter: counter))
        let run = Task { await orchestrator.run(record.id) }

        // Cancel once the first upload has started.
        var started = false
        for _ in 0..<200 where !started {
            try await Task.sleep(for: .milliseconds(50))
            started = (await firstStore.record(id: record.id))?.items.contains { $0.putStarted } ?? false
        }
        #expect(started, "no upload started in time")
        run.cancel()
        await run.value

        let cancelled = try #require(await firstStore.record(id: record.id))
        #expect(cancelled.status == .cancelled)
        #expect(cancelled.counts.ready < 8, "the cancel landed too late to interrupt anything")

        // "Relaunch": new store over the same file, new orchestrator, plain client.
        let reopened = TransferQueueStore(fileURL: file)
        await TransferOrchestrator(liveRuntime(api: try client(), store: reopened, counter: counter)).run(record.id)

        let done = try #require(await reopened.record(id: record.id))
        #expect(done.status == .completed, "paused reason: \(done.pausedReason ?? "none")")
        #expect(done.items.allSatisfy { $0.phase == .ready })
        #expect(counter.counts.withLock { $0.count } == 8)
        #expect(counter.counts.withLock { $0.values.allSatisfy { $0 == 1 } }, "a photo was rendered more than once")

        let remote = try await client().transferStatus(transferID: try #require(done.remoteTransferID))
        #expect(remote.items.count == 8)
        #expect(Set(remote.items.map(\.itemId)).count == 8)
        #expect(remote.items.allSatisfy { $0.status == .ready && $0.publicationState == "draft" })
    }

    @Test func theManifestIsIdempotentAndAChangedSizeIsRejected() async throws {
        let id = "pme-live-\(UUID().uuidString.lowercased())"
        let tempA = try TempDirectory()
        let tempB = try TempDirectory()
        let counter = RenderCounter()

        // Two separate queue records (and stores) carrying the same client transfer id and items.
        var results: [StudioOSRemoteTransfer] = []
        for temp in [tempA, tempB] {
            let store = TransferQueueStore(fileURL: temp.url.appendingPathComponent("transfers.json"))
            let record = try liveRecord(temp, items: 3, id: id)
            try await store.upsert(record)
            await TransferOrchestrator(liveRuntime(api: try client(), store: store, counter: counter)).run(id)
            let done = try #require(await store.record(id: id))
            #expect(done.status == .completed, "paused reason: \(done.pausedReason ?? "none")")
            results.append(try await client().transferStatus(transferID: try #require(done.remoteTransferID)))
        }
        #expect(results[0].transferId == results[1].transferId)
        #expect(results[0].items.map(\.itemId) == results[1].items.map(\.itemId))
        #expect(results[0].items.map(\.mediaId) == results[1].items.map(\.mediaId))
        #expect(results[1].items.count == 3)

        // Directly through the client: the same manifest twice returns the same ids...
        func sha(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
        let directID = "pme-live-\(UUID().uuidString.lowercased())"
        let manifest = StudioOSCreateTransfer(
            clientTransferId: directID, galleryId: Live.galleryID,
            items: (0..<2).map {
                StudioOSManifestItem(clientItemId: "d\($0)", fileName: "d\($0).jpg", sizeBytes: 1000 + $0, sha256: sha("d\($0)"), position: $0)
            }
        )
        let first = try await client().createTransfer(manifest)
        let second = try await client().createTransfer(manifest)
        #expect(first.transferId == second.transferId)
        #expect(first.items.map(\.itemId) == second.items.map(\.itemId))
        #expect(first.items.map(\.mediaId) == second.items.map(\.mediaId))

        // ...and a changed size under the same id is refused.
        var changed = manifest
        changed.items[0].sizeBytes += 1
        do {
            _ = try await client().createTransfer(changed)
            Issue.record("a manifest with a changed size was accepted")
        } catch StudioOSError.rejected(let status, _) {
            #expect(status == 409)
        }
    }

    @Test(.enabled(if: Live.revokedEnabled))
    func aRevokedTokenPausesWithRenderedFilesKept() async throws {
        let temp = try TempDirectory()
        let store = TransferQueueStore(fileURL: temp.url.appendingPathComponent("transfers.json"))
        let counter = RenderCounter()
        let record = try liveRecord(temp, items: 3)
        try await store.upsert(record)
        let revoked = StudioOSClient(connection: try Live.connection(token: Live.env["PME_STUDIOOS_LIVE_REVOKED_TOKEN"]))

        await TransferOrchestrator(liveRuntime(api: revoked, store: store, counter: counter)).run(record.id)

        let paused = try #require(await store.record(id: record.id))
        #expect(paused.status == .paused)
        #expect(paused.pausedReason?.contains("not paired") == true)
        #expect(paused.items.allSatisfy { $0.phase == .rendered })
        #expect(paused.items.allSatisfy { FileManager.default.fileExists(atPath: $0.stagedPath ?? "") })
        #expect(counter.total == 3)
    }
}
