import AppKit
import CoreImage
import MetalKit
import SwiftUI

/// Where a photo lands inside a canvas. Pure so the fit can be tested without a GPU.
enum PhotoCanvasLayout {
    /// The largest rectangle with the image's aspect ratio that fits `canvas`, centered.
    nonisolated static func fitRect(imageSize: CGSize, in canvas: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, canvas.width > 0, canvas.height > 0 else { return .zero }
        let scale = min(canvas.width / imageSize.width, canvas.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}

/// Draws photos on the GPU. One device, queue, and Core Image context are shared by every canvas.
final class PhotoCanvasRenderer: @unchecked Sendable {
    static let shared = PhotoCanvasRenderer()

    let device: MTLDevice?
    let queue: MTLCommandQueue?
    let context: CIContext?

    private init() {
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        queue = device?.makeCommandQueue()
        context = device.map { CIContext(mtlDevice: $0, options: [.cacheIntermediates: false]) }
    }

    /// The photo fitted and centered in a transparent canvas of `canvasSize` pixels, with its
    /// top edge at the top of the canvas (Core Image's origin is bottom-left).
    nonisolated static func composed(_ image: CIImage, canvasSize: CGSize) -> CIImage {
        let canvas = CGRect(origin: .zero, size: canvasSize)
        let clear = CIImage(color: .clear).cropped(to: canvas)
        let extent = image.extent
        let fit = PhotoCanvasLayout.fitRect(imageSize: extent.size, in: canvasSize)
        guard !fit.isEmpty else { return clear }
        let scale = fit.width / extent.width
        let placed = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: fit.minX, y: fit.minY))
            .samplingLinear()
        return placed.composited(over: clear).cropped(to: canvas)
    }

    /// Draws `image` fitted into `texture` and encodes it on `buffer`. The caller presents and commits.
    func draw(_ image: CIImage?, into texture: MTLTexture, colorSpace: CGColorSpace?, buffer: MTLCommandBuffer) throws {
        guard let context else { return }
        let size = CGSize(width: texture.width, height: texture.height)
        let frame = Self.composed(image ?? CIImage.empty(), canvasSize: size)
        let destination = CIRenderDestination(
            width: texture.width, height: texture.height, pixelFormat: texture.pixelFormat,
            commandBuffer: buffer, mtlTextureProvider: { texture })
        destination.isFlipped = true
        destination.alphaMode = .premultiplied
        destination.colorSpace = colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)
        _ = try context.startTask(toRender: frame, from: CGRect(origin: .zero, size: size),
                                  to: destination, at: .zero)
    }
}

/// A Metal view showing one photo. The photo is drawn by Core Image straight into the drawable,
/// color-managed for the window's display, so SwiftUI never caches or re-decodes the image.
final class PhotoMTKView: MTKView {
    private var ciImage: CIImage?
    private var source: CGImage?

    init() {
        super.init(frame: .zero, device: PhotoCanvasRenderer.shared.device)
        framebufferOnly = false
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        isPaused = true
        enableSetNeedsDisplay = true
        autoResizeDrawable = true
        (layer as? CAMetalLayer)?.isOpaque = false
        applyDisplayColorSpace()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ image: CGImage?) {
        guard image !== source else { return }
        source = image
        ciImage = image.map { CIImage(cgImage: $0) }
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyDisplayColorSpace()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyDisplayColorSpace()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func applyDisplayColorSpace() {
        let space = window?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)
        (layer as? CAMetalLayer)?.colorspace = space
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let renderer = PhotoCanvasRenderer.shared
        guard let queue = renderer.queue,
              drawableSize.width >= 1, drawableSize.height >= 1,
              let drawable = currentDrawable, let buffer = queue.makeCommandBuffer() else {
            PhotoPreviewDiagnostics.record("metal canvas skipped draw drawable=\(Int(drawableSize.width))x\(Int(drawableSize.height)) hasWindow=\(window != nil) image=\(ciImage != nil)")
            return
        }

        do {
            try renderer.draw(ciImage, into: drawable.texture,
                              colorSpace: (layer as? CAMetalLayer)?.colorspace, buffer: buffer)
        } catch {
            PhotoPreviewDiagnostics.record("metal canvas render failed: \(error.localizedDescription)")
        }
        buffer.addCompletedHandler { buffer in
            PhotoPreviewDiagnostics.record("metal canvas buffer status=\(buffer.status.rawValue) error=\(buffer.error?.localizedDescription ?? "none")")
        }
        buffer.present(drawable)
        buffer.commit()
        PhotoPreviewDiagnostics.record("metal canvas drew width=\(Int(drawableSize.width)) height=\(Int(drawableSize.height)) image=\(ciImage != nil)")
    }
}

/// SwiftUI wrapper. It fills the space it is given and fits the photo inside, like `scaledToFit`.
struct MetalPhotoCanvas: NSViewRepresentable {
    let image: CGImage

    func makeNSView(context: Context) -> PhotoMTKView {
        let view = PhotoMTKView()
        view.show(image)
        return view
    }

    func updateNSView(_ view: PhotoMTKView, context: Context) {
        view.show(image)
    }
}

enum PhotoCanvasSetting {
    /// Metal is the default. Set `PME_SystemImageCanvas` (environment or user default) to compare
    /// against the SwiftUI image canvas, or when no Metal device exists.
    static var usesMetal: Bool {
        guard PhotoCanvasRenderer.shared.device != nil else { return false }
        if ProcessInfo.processInfo.environment["PME_SystemImageCanvas"] == "1" { return false }
        return !UserDefaults.standard.bool(forKey: "PME_SystemImageCanvas")
    }
}

extension NSImage {
    /// The image's bitmap when it is backed by one `CGImage` (every preview the renderer publishes).
    var backingCGImage: CGImage? {
        var rect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
