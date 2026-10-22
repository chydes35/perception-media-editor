import Foundation
import Metal

/// Reusable GPU-only `rgba16Float` frames, so playback does not allocate a 4K texture (66 MB) per
/// frame. Free textures are capped; extras are dropped rather than hoarded.
final class VideoTexturePool: @unchecked Sendable {
    private struct Key: Hashable { var width: Int; var height: Int }

    private let device: MTLDevice
    private let maximumFreeTextures: Int
    private let lock = NSLock()
    private var free: [(key: Key, texture: MTLTexture)] = []
    private var allocated = 0

    init(device: MTLDevice, maximumFreeTextures: Int = 6) {
        self.device = device
        self.maximumFreeTextures = maximumFreeTextures
    }

    /// Textures that exist, in use or waiting.
    var allocatedCount: Int { lock.withLock { allocated } }
    var freeCount: Int { lock.withLock { free.count } }

    func acquire(width: Int, height: Int) -> MTLTexture {
        let key = Key(width: width, height: height)
        lock.lock()
        if let index = free.firstIndex(where: { $0.key == key }) {
            let texture = free.remove(at: index).texture
            lock.unlock()
            return texture
        }
        allocated += 1
        lock.unlock()
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)!
    }

    func release(_ texture: MTLTexture) {
        let key = Key(width: texture.width, height: texture.height)
        lock.lock()
        defer { lock.unlock() }
        if free.count < maximumFreeTextures {
            free.append((key, texture))
        } else {
            allocated -= 1
        }
    }

    /// Drops every waiting texture, for memory pressure.
    func flush() {
        lock.lock()
        defer { lock.unlock() }
        allocated -= free.count
        free.removeAll()
    }
}
