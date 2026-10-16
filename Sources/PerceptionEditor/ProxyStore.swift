// Sources/PerceptionEditor/ProxyStore.swift
import Foundation

enum ProxyStatus: Equatable, Sendable {
    case missing
    case queued
    case generating(Double)
    case ready(URL)
    case failed(String)
}

/// Owns proxy status and runs one generation at a time. Proxies are a disposable cache keyed by
/// source content; deleting the directory never loses edits, it only costs regeneration time.
@MainActor
final class ProxyStore: ObservableObject {
    nonisolated static let directoryDefaultsKey = "perceptionEditor.proxyDirectory"
    nonisolated static let reserveBytes: Int64 = 2 * 1_024 * 1_024 * 1_024

    @Published private(set) var statuses: [UUID: ProxyStatus] = [:]
    var onReady: ((UUID) -> Void)?

    let directory: URL
    private let maximumSize: CGSize
    private let availableBytes: @Sendable (URL) -> Int64?
    private var queue: [MediaAsset] = []
    private var worker: Task<Void, Never>?
    /// A cancelled worker may still be unwinding when a new one starts; only the current one clears `worker`.
    private var workerToken = UUID()

    init(
        directory: URL = ProxyStore.defaultDirectory(),
        maximumSize: CGSize = ProxyGenerator.defaultMaximumSize,
        availableBytes: @escaping @Sendable (URL) -> Int64? = ProxyStore.availableBytes
    ) {
        self.directory = directory
        self.maximumSize = maximumSize
        self.availableBytes = availableBytes
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    nonisolated static func defaultDirectory() -> URL {
        if let path = UserDefaults.standard.string(forKey: directoryDefaultsKey) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("Perception Media Editor", isDirectory: true)
            .appendingPathComponent("Proxy Cache", isDirectory: true)
    }

    nonisolated static func availableBytes(_ url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    var readyURLs: [UUID: URL] {
        statuses.compactMapValues { status -> URL? in
            guard case .ready(let url) = status else { return nil }
            return url
        }
    }

    func readyURL(for assetID: UUID) -> URL? {
        if case .ready(let url) = statuses[assetID] { url } else { nil }
    }

    func enqueue(_ assets: [MediaAsset], prioritized: Set<UUID> = []) {
        let pending = Set(queue.map(\.id))
        let fresh = assets.filter { asset in
            guard asset.kind == .video, !pending.contains(asset.id) else { return false }
            switch statuses[asset.id] {
            case .queued?, .generating?, .ready?: return false
            default: return true
            }
        }
        for asset in fresh { statuses[asset.id] = .queued }
        queue.append(contentsOf: fresh)
        queue.sort { prioritized.contains($0.id) && !prioritized.contains($1.id) }
        startWorkerIfNeeded()
    }

    /// Forget an asset's status after relink or when its proxy file disappeared.
    func invalidate(assetID: UUID) {
        queue.removeAll { $0.id == assetID }
        statuses[assetID] = nil
    }

    func cancelAll() {
        worker?.cancel()
        worker = nil
        for asset in queue { statuses[asset.id] = .missing }
        queue = []
        for (id, status) in statuses { if case .generating = status { statuses[id] = .missing } }
    }

    func removeAllProxies() throws {
        cancelAll()
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for url in contents where url.pathExtension == "mov" { try FileManager.default.removeItem(at: url) }
        statuses = [:]
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, !queue.isEmpty else { return }
        let token = UUID()
        workerToken = token
        worker = Task { [weak self] in
            while let self, !Task.isCancelled, !self.queue.isEmpty {
                let asset = self.queue.removeFirst()
                await self.process(asset)
            }
            if let self, self.workerToken == token { self.worker = nil }
        }
    }

    private func process(_ asset: MediaAsset) async {
        let directory = directory
        let maximumSize = maximumSize
        let availableBytes = availableBytes
        let assetID = asset.id
        statuses[assetID] = .generating(0)

        let job = Task.detached(priority: .utility) { () throws -> URL in
            let key = try ProxyFingerprint.key(for: asset.url)
            let destination = directory.appendingPathComponent(key).appendingPathExtension("mov")
            if FileManager.default.fileExists(atPath: destination.path) { return destination }

            let size = ProxyGenerator.proxySize(
                for: CGSize(width: asset.pixelWidth ?? 3840, height: asset.pixelHeight ?? 2160), maximum: maximumSize
            )
            let needed = ProxyGenerator.estimatedBytes(durationSeconds: asset.durationSeconds ?? 0, proxySize: size)
                + ProxyStore.reserveBytes
            if let available = availableBytes(directory), available < needed {
                throw ProxyError.insufficientSpace(neededBytes: needed, availableBytes: available)
            }
            return try await ProxyGenerator.generate(source: asset.url, destination: destination, maximumSize: maximumSize) { fraction in
                Task { @MainActor [weak self] in
                    guard let self, case .generating = self.statuses[assetID] else { return }
                    self.statuses[assetID] = .generating(fraction)
                }
            }.url
        }

        let outcome = await withTaskCancellationHandler {
            await job.result
        } onCancel: {
            job.cancel()
        }
        guard !Task.isCancelled else { return }
        switch outcome {
        case .success(let url):
            statuses[assetID] = .ready(url)
            onReady?(assetID)
        case .failure(let error as ProxyError):
            statuses[assetID] = .failed(error.errorDescription ?? "Proxy failed")
        case .failure(is CancellationError):
            statuses[assetID] = .missing
        case .failure(let error):
            statuses[assetID] = .failed(error.localizedDescription)
        }
    }
}
