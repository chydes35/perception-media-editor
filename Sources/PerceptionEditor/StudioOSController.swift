import Combine
import Foundation
import UniformTypeIdentifiers

struct StudioOSSendItem: Sendable {
    let assetID: UUID
    let source: URL
    let adjustments: PhotoAdjustments
}

/// Everything the UI needs for Studio OS. `EditorStore` owns one but does not otherwise know
/// about connectivity, queues or uploads.
@MainActor
final class StudioOSController: ObservableObject {
    enum Link: Equatable {
        case notPaired
        case checking
        case connected(storage: String)
        case unreachable(String)
        case unauthorized
    }

    @Published private(set) var connection: StudioOSConnection?
    @Published private(set) var link: Link = .notPaired
    @Published private(set) var destinations: [StudioOSDestination] = []
    @Published private(set) var transfers: [TransferRecord] = []
    /// A pairing link the user has not yet confirmed. Nothing is saved until they do.
    @Published private(set) var pendingPairing: StudioOSConnection?
    @Published var lastError: String?

    private let credentials: any StudioOSCredentialStoring
    private let defaults: UserDefaults
    private let store: TransferQueueStore
    private let makeAPI: @Sendable (StudioOSConnection) -> any StudioOSAPI
    private let renderOverride: (@Sendable (TransferItemRecord, URL, TransferRecord) async throws -> Void)?
    /// Built on first use: creating a `PhotoRenderer` is not free and most sessions never send.
    private lazy var defaultRender = Self.photoRendererRender()
    private let freeSpace: @Sendable (URL) -> Int64
    private let pollInterval: Duration
    private var tasks: [String: Task<Void, Never>] = [:]
    private var didStart = false
    private var refreshGeneration = 0

    private enum Key {
        static let server = "studioOS.serverURL"
        static let web = "studioOS.webURL"
        static let staging = "studioOS.stagingFolder"
        static let lastDestination = "studioOS.lastDestinationGalleryID"
    }

    init(
        credentials: any StudioOSCredentialStoring = KeychainCredentialStore(),
        defaults: UserDefaults = .standard,
        store: TransferQueueStore = TransferQueueStore(fileURL: TransferQueueStore.defaultFileURL()),
        makeAPI: @escaping @Sendable (StudioOSConnection) -> any StudioOSAPI = { StudioOSClient(connection: $0) },
        render: (@Sendable (TransferItemRecord, URL, TransferRecord) async throws -> Void)? = nil,
        freeSpace: @escaping @Sendable (URL) -> Int64 = TransferRuntime.volumeFreeSpace,
        pollInterval: Duration = .seconds(3)
    ) {
        self.credentials = credentials
        self.defaults = defaults
        self.store = store
        self.makeAPI = makeAPI
        self.renderOverride = render
        self.freeSpace = freeSpace
        self.pollInterval = pollInterval
        loadStoredConnection()
    }

    /// Loads the saved transfer list once. Called by the Studio OS panel when it appears.
    func start() async {
        guard !didStart else { return }
        didStart = true
        await loadStoredTransfers()
    }

    // MARK: - Settings

    /// Staging defaults to Application Support; the owner can point it at the external SSD.
    var stagingFolder: URL {
        get {
            if let path = defaults.string(forKey: Key.staging) { return URL(fileURLWithPath: path, isDirectory: true) }
            return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PerceptionMediaEditor/StudioOSStaging", isDirectory: true)
        }
        set { defaults.set(newValue.path, forKey: Key.staging) }
    }

    /// Only a suggestion for the destination picker; never applied silently.
    var lastDestinationID: String? {
        get { defaults.string(forKey: Key.lastDestination) }
        set { defaults.set(newValue, forKey: Key.lastDestination) }
    }

    // MARK: - Pairing

    func handlePairingURL(_ url: URL) {
        do {
            pendingPairing = try StudioOSPairing.connection(from: url)
        } catch {
            pendingPairing = nil
            lastError = error.localizedDescription
        }
    }

    func confirmPendingPairing() throws {
        guard let pending = pendingPairing else { return }
        try save(pending)
        pendingPairing = nil
    }

    func cancelPendingPairing() { pendingPairing = nil }

    func pair(server: String, web: String?, token: String) throws {
        try save(StudioOSPairing.validate(server: server, web: web, token: token))
    }

    func disconnect() {
        try? credentials.deleteToken()
        defaults.removeObject(forKey: Key.server)
        defaults.removeObject(forKey: Key.web)
        connection = nil
        link = .notPaired
        destinations = []
    }

    private func save(_ connection: StudioOSConnection) throws {
        try credentials.saveToken(connection.token)
        defaults.set(connection.serverURL.absoluteString, forKey: Key.server)
        if let web = connection.webURL { defaults.set(web.absoluteString, forKey: Key.web) } else { defaults.removeObject(forKey: Key.web) }
        self.connection = connection
        link = .checking
    }

    private func loadStoredConnection() {
        guard let server = defaults.string(forKey: Key.server),
              let token = try? credentials.loadToken(),
              let connection = try? StudioOSPairing.validate(
                  server: server, web: defaults.string(forKey: Key.web), token: token
              )
        else { return }
        self.connection = connection
        link = .checking
    }

    // MARK: - Connection and destinations

    func checkConnection() async {
        guard let connection else { link = .notPaired; return }
        link = .checking
        do {
            let health = try await makeAPI(connection).health()
            link = .connected(storage: health.storage)
        } catch StudioOSError.notPaired {
            link = .unauthorized
        } catch {
            link = .unreachable(error.localizedDescription)
        }
    }

    /// Returns true when the list was refreshed; false when it failed (the error is in `lastError`).
    @discardableResult
    func loadDestinations() async -> Bool {
        guard let connection else { return false }
        do {
            destinations = try await makeAPI(connection).destinations()
            return true
        } catch StudioOSError.notPaired {
            link = .unauthorized
            lastError = StudioOSError.notPaired.localizedDescription
        } catch {
            lastError = error.localizedDescription
        }
        return false
    }

    // MARK: - Transfers

    @discardableResult
    func enqueue(
        items: [StudioOSSendItem], destination: StudioOSDestination,
        recipe: BatchExportRecipe, protecting originals: [URL]
    ) async throws -> String {
        guard let connection else { throw StudioOSError.notPaired }
        guard !items.isEmpty else { throw BatchExportError.noPhotosSelected }
        try recipe.validate()

        let id = "pme-\(UUID().uuidString.lowercased())"
        let label = Self.label(for: destination)
        let record = TransferRecord(
            id: id, serverURL: connection.serverURL, webURL: connection.webURL,
            galleryID: destination.galleryId, bookingID: destination.bookingId,
            destinationLabel: label, createdAt: Date(),
            jpegQuality: recipe.jpegQuality, longEdgePixels: recipe.longEdgePixels,
            protectedOriginalPaths: originals.map(\.path),
            stagingFolderPath: stagingFolder.appendingPathComponent(id, isDirectory: true).path,
            remoteTransferID: nil, status: .running, pausedReason: nil,
            items: items.enumerated().map { index, item in
                let stem = item.source.deletingPathExtension().lastPathComponent
                return TransferItemRecord(
                    id: item.assetID.uuidString.lowercased(), position: index,
                    sourcePath: item.source.path, adjustments: item.adjustments,
                    displayName: item.source.lastPathComponent,
                    uploadFileName: (stem.isEmpty ? "Photo" : stem) + ".jpg"
                )
            }
        )
        // Persist before anything runs, so a crash right after Send still leaves a resumable record.
        try await store.upsert(record)
        lastDestinationID = destination.galleryId
        transfers.append(record)
        tasks[id] = Task { [weak self] in await self?.runTransfer(id) }
        return id
    }

    func resume(_ id: String) {
        guard tasks[id] == nil else { return }
        tasks[id] = Task { [weak self] in await self?.runTransfer(id) }
    }

    func cancel(_ id: String) { tasks[id]?.cancel() }

    func retryFailed(_ id: String) {
        guard tasks[id] == nil, let orchestrator = makeOrchestrator() else { return }
        tasks[id] = Task { [weak self] in
            await orchestrator.retryFailedItems(id)
            await orchestrator.run(id)
            await self?.finishedRun(id)
        }
    }

    /// Removes this app's staging files and the local record. It never deletes anything on Studio OS.
    func discardLocal(_ id: String) async {
        tasks[id]?.cancel()
        await tasks[id]?.value
        if let record = await store.record(id: id) {
            let folder = URL(fileURLWithPath: record.stagingFolderPath, isDirectory: true)
            if Self.isSafeToDelete(stagingFolder: folder, record: record) {
                try? FileManager.default.removeItem(at: folder)
            } else {
                lastError = "The staging folder recorded for this transfer looks unsafe, so it was left in place."
            }
        }
        try? await store.remove(id: id)
        await refreshTransfers()
    }

    /// The queue file is plain JSON, so a path read from it is not trusted. Only a folder this app
    /// could have created (named after the record, never a symlink, never near the originals) is removed.
    static func isSafeToDelete(stagingFolder: URL, record: TransferRecord) -> Bool {
        guard record.id.hasPrefix("pme-"), record.id.count > 4 else { return false }
        let standardized = stagingFolder.standardizedFileURL
        guard standardized.lastPathComponent == record.id else { return false }
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: standardized.path)) != nil { return false }
        let resolved = standardized.resolvingSymlinksInPath()
        guard resolved.lastPathComponent == record.id else { return false }
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        guard resolved.path != "/", resolved.path != home else { return false }
        let prefix = resolved.path + "/"
        for original in record.protectedOriginalPaths {
            let path = URL(fileURLWithPath: original).standardizedFileURL.resolvingSymlinksInPath().path
            if path == resolved.path || path.hasPrefix(prefix) { return false }
        }
        return true
    }

    func openURL(for record: TransferRecord) -> URL? {
        record.webURL?.appendingPathComponent("bookings/\(record.bookingID)")
    }

    func waitUntilIdle() async {
        for task in tasks.values { await task.value }
    }

    // MARK: - Internals

    private func runTransfer(_ id: String) async {
        guard let orchestrator = makeOrchestrator() else {
            await finishedRun(id)
            return
        }
        await orchestrator.run(id)
        await finishedRun(id)
    }

    private func finishedRun(_ id: String) async {
        tasks[id] = nil
        await refreshTransfers()
    }

    private func makeOrchestrator() -> TransferOrchestrator? {
        guard let connection else { lastError = StudioOSError.notPaired.localizedDescription; return nil }
        let runtime = TransferRuntime(
            api: makeAPI(connection), store: store, render: renderOverride ?? defaultRender,
            freeSpace: freeSpace,
            // The stored state is the source of truth; a snapshot delivered late could be stale.
            onChange: { [weak self] _ in
                Task { @MainActor [weak self] in await self?.refreshTransfers() }
            },
            pollInterval: pollInterval
        )
        return TransferOrchestrator(runtime)
    }

    /// Only the most recently started refresh may publish, so an older read can never
    /// overwrite a newer one.
    private func refreshTransfers() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        let latest = await store.all()
        guard generation == refreshGeneration else { return }
        transfers = latest
    }

    private func loadStoredTransfers() async {
        // A transfer still marked running with no live task was interrupted by quitting.
        for record in await store.all() where record.status == .running && tasks[record.id] == nil {
            await Self.markInterrupted(record.id, in: store)
        }
        if let warning = await store.loadWarning() { lastError = warning }
        await refreshTransfers()
    }

    /// Nonisolated so the mutation closure is built outside the main actor and can enter the store actor.
    private nonisolated static func markInterrupted(_ id: String, in store: TransferQueueStore) async {
        _ = try? await store.update(id: id) { stored in
            stored.status = .paused
            stored.pausedReason = "Interrupted when the app was closed. Resume to continue."
        }
    }

    private static func label(for destination: StudioOSDestination) -> String {
        var label = "\(destination.clientName) — \(destination.shootType)"
        if let date = destination.scheduledAt {
            label += " (\(date.formatted(date: .abbreviated, time: .omitted)))"
        }
        return label
    }

    /// One shared renderer with the same memory budget as batch export; one photo at a time.
    private static func photoRendererRender() -> @Sendable (TransferItemRecord, URL, TransferRecord) async throws -> Void {
        let renderer = PhotoRenderer(workingCacheLimit: 0, memoryTargetMB: 128)
        return { item, destination, record in
            try await renderer.export(
                url: URL(fileURLWithPath: item.sourcePath), adjustments: item.adjustments,
                to: destination, type: .jpeg, quality: record.jpegQuality,
                protectedOriginals: record.protectedOriginalPaths.map { URL(fileURLWithPath: $0) },
                longEdgePixels: record.longEdgePixels, replaceExisting: true
            )
        }
    }
}
