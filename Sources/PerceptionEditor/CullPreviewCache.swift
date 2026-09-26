import AppKit

/// Keeps a few screen-sized previews in memory around the photo being culled, so moving to the
/// next or previous photo shows it immediately instead of waiting on a decode.
///
/// Decodes happen on background threads. At most `limit` previews are kept (about 10–17 MB each),
/// which bounds memory on an 8 GB Mac regardless of how many photos are in the shoot.
@MainActor
final class CullPreviewCache {
    private var images: [UUID: (url: URL, image: NSImage)] = [:]
    private var order: [UUID] = []
    private var pending: Set<UUID> = []
    private let limit: Int

    /// Called on the main actor when a requested preview has finished loading.
    var onLoaded: ((UUID) -> Void)?

    init(limit: Int = 10) {
        self.limit = limit
    }

    var cachedCount: Int { images.count }

    /// The cached preview, marking it as recently used. Nil until it has been prefetched.
    func image(for asset: MediaAsset) -> NSImage? {
        guard let entry = images[asset.id], entry.url == asset.url else { return nil }
        touch(asset.id)
        return entry.image
    }

    /// Starts loading any of `assets` that are not cached. Earlier assets load first.
    func prefetch(_ assets: [MediaAsset]) {
        for asset in assets where asset.kind == .photo {
            if let entry = images[asset.id], entry.url == asset.url { continue }
            guard !pending.contains(asset.id) else { continue }
            pending.insert(asset.id)

            let id = asset.id
            let url = asset.url
            Task.detached(priority: .userInitiated) { [weak self] in
                let rendered = PhotoSourceLoader.loadCullPreview(url).map(RenderedImage.init)
                await self?.finish(id: id, url: url, rendered: rendered)
            }
        }
    }

    func remove(_ id: UUID) {
        images[id] = nil
        order.removeAll { $0 == id }
    }

    func clear() {
        images = [:]
        order = []
        pending = []
    }

    private func finish(id: UUID, url: URL, rendered: RenderedImage?) {
        pending.remove(id)
        guard let rendered else { return }

        let cgImage = rendered.cgImage
        images[id] = (url, NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)))
        touch(id)
        while order.count > limit, let oldest = order.first {
            order.removeFirst()
            images[oldest] = nil
        }
        onLoaded?(id)
    }

    private func touch(_ id: UUID) {
        order.removeAll { $0 == id }
        order.append(id)
    }
}
