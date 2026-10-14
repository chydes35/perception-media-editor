import AppKit

/// Six completed previews and at most two active decodes. Navigation replaces the queued
/// neighborhood; a cancelled synchronous decode occupies its slot until it actually returns.
@MainActor
final class CullPreviewCache {
    private struct Request: Equatable, Sendable {
        var id: UUID
        var url: URL
    }
    private struct Flight {
        var request: Request
        var task: Task<Void, Never>
    }
    private var images: [UUID: (url: URL, image: NSImage)] = [:]
    private var order: [UUID] = []
    private var wanted: [Request] = []
    private var queued: [Request] = []
    private var active: [UUID: Flight] = [:]
    private let limit: Int
    private let maximumConcurrentDecodes: Int
    private let loader: @Sendable (URL) async -> RenderedImage?

    var onLoaded: ((UUID) -> Void)?

    init(limit: Int = 6, maximumConcurrentDecodes: Int = 2,
         loader: @escaping @Sendable (URL) async -> RenderedImage? = { url in
             autoreleasepool { PhotoSourceLoader.loadCullPreview(url).map(RenderedImage.init) }
         }) {
        self.limit = max(1, limit)
        self.maximumConcurrentDecodes = max(1, maximumConcurrentDecodes)
        self.loader = loader
    }

    var cachedCount: Int { images.count }
    var activeDecodeCount: Int { active.count }
    var queuedDecodeCount: Int { queued.count }

    func image(for asset: MediaAsset) -> NSImage? {
        guard let entry = images[asset.id], entry.url == asset.url else { return nil }
        touch(asset.id)
        return entry.image
    }

    /// Earlier assets have priority. Only this latest neighborhood remains queued.
    func prefetch(_ assets: [MediaAsset]) {
        var seen: Set<UUID> = []
        wanted = assets.filter { $0.kind == .photo && seen.insert($0.id).inserted }
            .prefix(limit + 2).map { Request(id: $0.id, url: $0.url) }
        for flight in active.values where !wanted.contains(flight.request) { flight.task.cancel() }
        queued = wanted.filter { request in
            !isCached(request) && !active.values.contains { $0.request == request && !$0.task.isCancelled }
        }
        startQueuedDecodes()
    }

    func remove(_ id: UUID) {
        images[id] = nil
        order.removeAll { $0 == id }
        wanted.removeAll { $0.id == id }
        queued.removeAll { $0.id == id }
        for flight in active.values where flight.request.id == id { flight.task.cancel() }
        startQueuedDecodes()
    }

    func clear() {
        images = [:]
        order = []
        wanted = []
        queued = []
        for flight in active.values { flight.task.cancel() }
        // Keep active entries until completion, so clearing cannot launch another two decodes
        // while the previous RAW decoders are still using memory.
    }

    private func isCached(_ request: Request) -> Bool { images[request.id]?.url == request.url }

    private func startQueuedDecodes() {
        while active.count < maximumConcurrentDecodes {
            guard !queued.isEmpty else { return }
            let request = queued.removeFirst()
            guard !isCached(request), !active.values.contains(where: { $0.request == request && !$0.task.isCancelled }) else { continue }
            let token = UUID()
            let loader = loader
            let task = Task.detached(priority: .userInitiated) { [weak self] in
                let result = Task.isCancelled ? nil : await loader(request.url)
                await self?.finish(token: token, rendered: result)
            }
            active[token] = Flight(request: request, task: task)
        }
    }

    private func finish(token: UUID, rendered: RenderedImage?) {
        guard let flight = active.removeValue(forKey: token) else { return }
        defer { startQueuedDecodes() }
        guard !flight.task.isCancelled, wanted.contains(flight.request), let rendered else { return }
        let request = flight.request
        let cgImage = rendered.cgImage
        images[request.id] = (request.url, NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)))
        touch(request.id)
        while order.count > limit, let oldest = order.first {
            order.removeFirst()
            images[oldest] = nil
        }
        onLoaded?(request.id)
    }

    private func touch(_ id: UUID) {
        order.removeAll { $0 == id }
        order.append(id)
    }
}
