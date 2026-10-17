import Foundation
import Metal
import QuartzCore

/// Where the compositor leaves a small copy of the picture for the scopes. While enabled, frames at
/// least 1/20 s apart in the timeline are captured (every second frame of 24–30 fps playback, so
/// 12–15 updates a second, however the player paces its rendering), downsampled to 512 wide, into
/// one of three reused textures; only the latest is kept. A frame rendered after a pause in
/// rendering (a seek, a step) is always captured. Nothing is captured while the scope panel is hidden.
final class ScopeTap: @unchecked Sendable {
    static let shared = ScopeTap()
    static let ringSize = 3
    static let captureWidth = 512

    enum Source: String, CaseIterable, Identifiable, Sendable {
        /// The graded picture, as shown.
        case output = "Output"
        /// The decoded code values before source color and grading (log footage as recorded).
        case source = "Source"

        var id: String { rawValue }
    }

    private let lock = NSLock()
    private var enabled = false
    private var captureSource = Source.output
    private var interval: TimeInterval
    private var lastCapture: TimeInterval = -.infinity
    private var lastCompositionSeconds: Double?
    private var ring: [MTLTexture] = []
    private var next = 0
    private var latestTexture: MTLTexture?
    private var captured = 0
    private var published = 0
    private var listener: (@Sendable (MTLTexture) -> Void)?

    init(minimumInterval: TimeInterval = 1.0 / 20) {
        interval = minimumInterval
    }

    var isEnabled: Bool {
        get { lock.withLock { enabled } }
        set { lock.withLock { enabled = newValue; if newValue { lastCapture = -.infinity; lastCompositionSeconds = nil } } }
    }

    var source: Source {
        get { lock.withLock { captureSource } }
        set { lock.withLock { captureSource = newValue } }
    }

    var minimumInterval: TimeInterval {
        get { lock.withLock { interval } }
        set { lock.withLock { interval = newValue } }
    }

    var capturedCount: Int { lock.withLock { captured } }
    var publishedCount: Int { lock.withLock { published } }
    var latest: MTLTexture? { lock.withLock { latestTexture } }

    /// Called with each published capture, on the GPU's completion thread.
    func setListener(_ listener: (@Sendable (MTLTexture) -> Void)?) {
        lock.withLock { self.listener = listener }
    }

    /// Whether the frame at `compositionSeconds` (timeline time, when known) should be captured;
    /// reserves the capture when it should.
    func shouldCapture(compositionSeconds: Double? = nil, now: TimeInterval = CACurrentMediaTime()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard enabled else { return false }
        let wallClockDue = now - lastCapture >= interval
        // A frame's own time decides during playback, since players render in bursts. Half a
        // millisecond of slack keeps 1/20 s steps of 60 fps footage from rounding below the interval.
        let timelineDue = compositionSeconds.map { seconds in
            lastCompositionSeconds.map { abs(seconds - $0) >= interval - 0.0005 } ?? true
        } ?? false
        guard wallClockDue || timelineDue else { return false }
        lastCapture = now
        lastCompositionSeconds = compositionSeconds
        captured += 1
        return true
    }

    /// The next ring texture for a capture of `width`×`height`, replacing one of another size.
    func captureTexture(device: MTLDevice, width: Int, height: Int) -> MTLTexture? {
        lock.lock()
        defer { lock.unlock() }
        let slot = next % Self.ringSize
        next += 1
        if slot < ring.count, ring[slot].width == width, ring[slot].height == height { return ring[slot] }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        if slot < ring.count { ring[slot] = texture } else { ring.append(texture) }
        return texture
    }

    /// Drops the ring and the latest capture, for memory pressure. Captures still referenced by
    /// frames on the GPU or by the scope worker live until those finish; the next capture
    /// allocates afresh.
    func releaseTextures() {
        lock.withLock {
            ring.removeAll()
            latestTexture = nil
            next = 0
        }
    }

    /// The number of capture textures the tap holds.
    var heldTextureCount: Int { lock.withLock { ring.count } }

    /// The capture is complete on the GPU: it becomes the latest, and the listener hears of it.
    func publish(_ texture: MTLTexture) {
        lock.lock()
        latestTexture = texture
        published += 1
        let listener = listener
        lock.unlock()
        listener?(texture)
    }
}
