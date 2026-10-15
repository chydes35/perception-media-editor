import Foundation
import Testing
@testable import PerceptionEditor

@MainActor
struct StudioOSControllerTests {
    private let token = "pme_" + String(repeating: "c", count: 43)

    /// One defaults suite per temp directory, so each test can remove it again with `defer`.
    private func suiteName(_ temp: TempDirectory) -> String { "studio-os-tests-\(temp.url.lastPathComponent)" }
    private func removeDefaults(_ temp: TempDirectory) {
        UserDefaults(suiteName: suiteName(temp))?.removePersistentDomain(forName: suiteName(temp))
    }

    private func makeController(
        _ temp: TempDirectory, credentials: InMemoryCredentialStore = InMemoryCredentialStore(),
        api: FakeStudioOS = FakeStudioOS(), recorder: TransferRenderRecorder = TransferRenderRecorder()
    ) -> (StudioOSController, UserDefaults) {
        let suite = suiteName(temp)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let controller = StudioOSController(
            credentials: credentials, defaults: defaults,
            store: TransferQueueStore(fileURL: temp.url.appendingPathComponent("transfers.json")),
            makeAPI: { _ in api }, render: recorder.render(), freeSpace: { _ in .max },
            pollInterval: .milliseconds(5)
        )
        controller.stagingFolder = temp.url.appendingPathComponent("staging")
        return (controller, defaults)
    }

    /// A disposable stand-in for an original on a card: a run pauses when the original is missing.
    private func sourceFile(_ temp: TempDirectory, _ name: String) throws -> URL {
        let url = temp.url.appendingPathComponent(name)
        try Data("raw".utf8).write(to: url)
        return url
    }

    private func destination() -> StudioOSDestination {
        StudioOSDestination(galleryId: "gal_1", bookingId: "book_1", clientName: "Ada", shootType: "Wedding", scheduledAt: nil)
    }

    @Test func aPairingLinkNeverTakesEffectUntilConfirmed() throws {
        let temp = try TempDirectory()
        defer { removeDefaults(temp) }
        let credentials = InMemoryCredentialStore()
        let (controller, _) = makeController(temp, credentials: credentials)
        let link = URL(string: "perceptionedit://pair?server=https%3A%2F%2Fevil.example&token=\(token)")!

        controller.handlePairingURL(link)
        #expect(controller.pendingPairing?.serverURL.host == "evil.example")
        #expect(controller.connection == nil)
        #expect(try credentials.loadToken() == nil)

        controller.cancelPendingPairing()
        #expect(controller.pendingPairing == nil)
        #expect(try credentials.loadToken() == nil)

        controller.handlePairingURL(link)
        try controller.confirmPendingPairing()
        #expect(controller.connection?.serverURL.host == "evil.example")
        #expect(try credentials.loadToken() == token)
    }

    @Test func invalidLinksAreReportedNotQueued() throws {
        let temp = try TempDirectory()
        defer { removeDefaults(temp) }
        let (controller, _) = makeController(temp)
        controller.handlePairingURL(URL(string: "perceptionedit://pair?server=http%3A%2F%2Fremote.example&token=\(token)")!)
        #expect(controller.pendingPairing == nil)
        #expect(controller.lastError?.contains("https") == true)
    }

    @Test func pairingPersistsAcrossLaunchesAndDisconnectClearsTheCredential() async throws {
        let temp = try TempDirectory()
        defer { removeDefaults(temp) }
        let credentials = InMemoryCredentialStore()
        let (controller, defaults) = makeController(temp, credentials: credentials)
        try controller.pair(server: "http://localhost:3001", web: "http://localhost:3000", token: token)
        #expect(controller.connection?.token == token)

        // A fresh controller over the same stores comes back paired.
        let again = StudioOSController(
            credentials: credentials, defaults: defaults,
            store: TransferQueueStore(fileURL: temp.url.appendingPathComponent("transfers.json")),
            makeAPI: { _ in FakeStudioOS() }
        )
        #expect(again.connection?.serverURL.absoluteString == "http://localhost:3001")
        #expect(again.connection?.webURL?.absoluteString == "http://localhost:3000")

        controller.disconnect()
        #expect(controller.connection == nil)
        #expect(try credentials.loadToken() == nil)
    }

    @Test func disconnectStopsRunningTransfersAndDropsAnUnconfirmedPairing() async throws {
        let temp = try TempDirectory()
        defer { removeDefaults(temp) }
        let credentials = InMemoryCredentialStore()
        let api = FakeStudioOS()
        api.uploadDelay = .seconds(5)
        let (controller, _) = makeController(temp, credentials: credentials, api: api)
        try controller.pair(server: "http://localhost:3001", web: nil, token: token)
        let items = try (0..<3).map { StudioOSSendItem(assetID: UUID(), source: try sourceFile(temp, "D_\($0).RW2"), adjustments: PhotoAdjustments()) }
        let id = try await controller.enqueue(items: items, destination: destination(), recipe: BatchExportRecipe(), protecting: [])
        controller.handlePairingURL(URL(string: "perceptionedit://pair?server=https%3A%2F%2Fother.example&token=\(token)")!)
        #expect(controller.pendingPairing != nil)
        // Let the run reach its slow uploads.
        for _ in 0..<200 where api.state.withLock({ $0.inFlight }) == 0 { try await Task.sleep(for: .milliseconds(10)) }

        let started = ContinuousClock.now
        controller.disconnect()
        await controller.waitUntilIdle()

        #expect(ContinuousClock.now - started < .seconds(4))   // did not wait out the uploads
        let record = try #require(controller.transfers.first { $0.id == id })
        #expect(record.status == .cancelled || record.status == .paused)
        #expect(controller.pendingPairing == nil)
        #expect(controller.connection == nil)
        #expect(try credentials.loadToken() == nil)
    }

    @Test func connectionCheckDistinguishesStates() async throws {
        let temp = try TempDirectory()
        defer { removeDefaults(temp) }
        let api = FakeStudioOS()
        let (controller, _) = makeController(temp, api: api)
        #expect(controller.link == .notPaired)
        try controller.pair(server: "http://localhost:3001", web: nil, token: token)

        await controller.checkConnection()
        #expect(controller.link == .connected(storage: "ok"))

        api.state.withLock { $0.healthError = .notPaired }
        await controller.checkConnection()
        #expect(controller.link == .unauthorized)

        api.state.withLock { $0.healthError = .unreachable("connection refused") }
        await controller.checkConnection()
        #expect(controller.link == .unreachable(StudioOSError.unreachable("connection refused").localizedDescription))
    }

    @Test func enqueueSnapshotsAndRunsToCompletion() async throws {
        let temp = try TempDirectory()
        defer { removeDefaults(temp) }
        let recorder = TransferRenderRecorder()
        let (controller, _) = makeController(temp, recorder: recorder)
        try controller.pair(server: "http://localhost:3001", web: "http://localhost:3000", token: token)
        var adjustments = PhotoAdjustments()
        adjustments.exposure = 0.5
        let items = try (0..<3).map { StudioOSSendItem(assetID: UUID(), source: try sourceFile(temp, "IMG_\($0).RW2"), adjustments: adjustments) }

        let id = try await controller.enqueue(
            items: items, destination: destination(), recipe: BatchExportRecipe(), protecting: items.map(\.source)
        )
        await controller.waitUntilIdle()

        let record = try #require(controller.transfers.first { $0.id == id })
        #expect(record.status == .completed)
        #expect(record.destinationLabel.contains("Ada"))
        #expect(record.items.map(\.uploadFileName) == ["IMG_0.jpg", "IMG_1.jpg", "IMG_2.jpg"])
        #expect(controller.openURL(for: record)?.absoluteString == "http://localhost:3000/bookings/book_1")
        #expect(controller.lastDestinationID == "gal_1")
    }

    @Test func enqueueRequiresAConnectionAndPhotos() async throws {
        let temp = try TempDirectory()
        defer { removeDefaults(temp) }
        let (controller, _) = makeController(temp)
        await #expect(throws: StudioOSError.notPaired) {
            try await controller.enqueue(items: [], destination: destination(), recipe: BatchExportRecipe(), protecting: [])
        }
        try controller.pair(server: "http://localhost:3001", web: nil, token: token)
        await #expect(throws: BatchExportError.noPhotosSelected) {
            try await controller.enqueue(items: [], destination: destination(), recipe: BatchExportRecipe(), protecting: [])
        }
    }

    @Test func aTransferInterruptedByQuittingLoadsAsPausedAndCanResume() async throws {
        let temp = try TempDirectory()
        let file = temp.url.appendingPathComponent("transfers.json")
        let seedStore = TransferQueueStore(fileURL: file)
        var record = try withSourceFiles(sampleRecord(items: 2), in: temp.url)
        record.status = .running   // the app was quit mid-run
        record.stagingFolderPath = temp.url.appendingPathComponent("staging").path
        try await seedStore.upsert(record)

        let credentials = InMemoryCredentialStore()
        try credentials.saveToken(token)
        defer { removeDefaults(temp) }
        let defaults = UserDefaults(suiteName: suiteName(temp))!
        defaults.set("http://localhost:3001", forKey: "studioOS.serverURL")
        let controller = StudioOSController(
            credentials: credentials, defaults: defaults, store: TransferQueueStore(fileURL: file),
            makeAPI: { _ in FakeStudioOS() }, render: TransferRenderRecorder().render(),
            freeSpace: { _ in .max }, pollInterval: .milliseconds(5)
        )
        await controller.start()

        let loaded = try #require(controller.transfers.first)
        #expect(loaded.status == .paused)
        #expect(loaded.pausedReason?.contains("closed") == true)

        controller.resume(loaded.id)
        await controller.waitUntilIdle()
        #expect(controller.transfers.first?.status == .completed)
    }

    @Test func discardingRemovesLocalFilesAndTheRecordOnly() async throws {
        let temp = try TempDirectory()
        defer { removeDefaults(temp) }
        let (controller, _) = makeController(temp)
        try controller.pair(server: "http://localhost:3001", web: nil, token: token)
        let items = [StudioOSSendItem(assetID: UUID(), source: try sourceFile(temp, "A.RW2"), adjustments: PhotoAdjustments())]
        let id = try await controller.enqueue(items: items, destination: destination(), recipe: BatchExportRecipe(), protecting: [])
        await controller.waitUntilIdle()
        await controller.discardLocal(id)
        #expect(controller.transfers.isEmpty)
    }

    @Test func discardNeverDeletesAFolderThatIsNotNamedAfterTheRecord() async throws {
        let temp = try TempDirectory()
        defer { removeDefaults(temp) }
        let (controller, _) = makeController(temp)
        try controller.pair(server: "http://localhost:3001", web: nil, token: token)
        let victim = temp.url.appendingPathComponent("Card", isDirectory: true)
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        let sentinel = victim.appendingPathComponent("IMG_0001.RW2")
        try Data("x".utf8).write(to: sentinel)
        var record = sampleRecord(id: "pme-tampered")
        record.status = .completed
        record.stagingFolderPath = victim.path
        let store = TransferQueueStore(fileURL: temp.url.appendingPathComponent("transfers.json"))
        try await store.upsert(record)
        await controller.start()

        await controller.discardLocal("pme-tampered")

        #expect(FileManager.default.fileExists(atPath: sentinel.path))
        #expect(controller.transfers.isEmpty)
        #expect(controller.lastError?.contains("unsafe") == true)
    }

    @Test func discardNeverDeletesAnAncestorOfAnOriginal() async throws {
        let temp = try TempDirectory()
        defer { removeDefaults(temp) }
        let (controller, _) = makeController(temp)
        try controller.pair(server: "http://localhost:3001", web: nil, token: token)
        let folder = temp.url.appendingPathComponent("pme-ancestor", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = folder.appendingPathComponent("A.RW2")
        try Data("x".utf8).write(to: original)
        var record = sampleRecord(id: "pme-ancestor")
        record.status = .completed
        record.stagingFolderPath = folder.path
        record.protectedOriginalPaths = [original.path]
        let store = TransferQueueStore(fileURL: temp.url.appendingPathComponent("transfers.json"))
        try await store.upsert(record)
        await controller.start()

        await controller.discardLocal("pme-ancestor")

        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(controller.transfers.isEmpty)
    }

    @Test func discardRemovesTheStagingFolderNamedAfterTheRecord() async throws {
        let temp = try TempDirectory()
        defer { removeDefaults(temp) }
        let (controller, _) = makeController(temp)
        try controller.pair(server: "http://localhost:3001", web: nil, token: token)
        let folder = temp.url.appendingPathComponent("elsewhere/pme-normal", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent("A.jpg"))
        var record = sampleRecord(id: "pme-normal")
        record.status = .completed
        record.stagingFolderPath = folder.path
        let store = TransferQueueStore(fileURL: temp.url.appendingPathComponent("transfers.json"))
        try await store.upsert(record)
        await controller.start()

        await controller.discardLocal("pme-normal")

        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(controller.transfers.isEmpty)
        #expect(controller.lastError == nil)
    }
}
