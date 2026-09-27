import AppKit
import SwiftUI

/// View-only zoom for the photo canvas. The image, crop handles, and mask tools all use
/// the same transform, so their pointer coordinates stay aligned at every scale.
struct PhotoZoomViewport {
    private(set) var scale: CGFloat = 1
    private(set) var offset: CGSize = .zero

    static let minimumScale: CGFloat = 0.05
    static let maximumScale: CGFloat = 64

    var isFitted: Bool { abs(scale - 1) < 0.001 && abs(offset.width) < 0.001 && abs(offset.height) < 0.001 }

    mutating func reset() {
        scale = 1
        offset = .zero
    }

    mutating func zoom(
        by wheelDelta: CGFloat,
        precise: Bool,
        at pointer: CGPoint,
        viewport: CGSize,
        image: CGSize
    ) {
        guard wheelDelta.isFinite, viewport.width > 0, viewport.height > 0 else { return }
        // Trackpads report many small pixel deltas; notched wheels report one or a few lines.
        let sensitivity: CGFloat = precise ? 0.012 : 0.18
        let boundedDelta = min(80, max(-80, wheelDelta))
        let next = min(Self.maximumScale, max(Self.minimumScale, scale * exp(boundedDelta * sensitivity)))
        guard next != scale else { return }

        let ratio = next / scale
        let center = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        // Keep the pixel under the pointer in place while magnifying around the view center.
        offset = CGSize(
            width: (pointer.x - center.x) * (1 - ratio) + offset.width * ratio,
            height: (pointer.y - center.y) * (1 - ratio) + offset.height * ratio
        )
        scale = next
        constrainOffset(viewport: viewport, image: image)
    }

    /// Move an already zoomed photo with a pressed mouse wheel.
    mutating func pan(by translation: CGSize, viewport: CGSize, image: CGSize) {
        offset.width += translation.width
        offset.height += translation.height
        constrainOffset(viewport: viewport, image: image)
    }

    mutating func constrain(viewport: CGSize, image: CGSize) {
        constrainOffset(viewport: viewport, image: image)
    }

    /// Continue from the existing pixel-perfect focus view when the wheel first turns there.
    mutating func matchPixelView(
        center normalizedCenter: CGPoint,
        fullImage: CGSize,
        displayScale: CGFloat,
        viewport: CGSize,
        preview: CGSize
    ) {
        let frame = MaskEditingLayer.fittedFrame(in: viewport, image: preview)
        guard frame.width > 0, frame.height > 0, displayScale > 0 else { return }
        scale = min(Self.maximumScale, max(Self.minimumScale,
            fullImage.width / (frame.width * displayScale)
        ))
        offset = CGSize(
            width: -scale * (frame.minX + normalizedCenter.x * frame.width - viewport.width / 2),
            height: -scale * (frame.minY + normalizedCenter.y * frame.height - viewport.height / 2)
        )
        constrainOffset(viewport: viewport, image: preview)
    }

    private mutating func constrainOffset(viewport: CGSize, image: CGSize) {
        let frame = MaskEditingLayer.fittedFrame(in: viewport, image: image)
        guard frame.width > 0, frame.height > 0 else {
            offset = .zero
            return
        }
        offset.width = Self.constrained(
            offset.width, imageMin: frame.minX, imageMax: frame.maxX,
            viewportLength: viewport.width, scale: scale
        )
        offset.height = Self.constrained(
            offset.height, imageMin: frame.minY, imageMax: frame.maxY,
            viewportLength: viewport.height, scale: scale
        )
    }

    private static func constrained(
        _ value: CGFloat, imageMin: CGFloat, imageMax: CGFloat,
        viewportLength: CGFloat, scale: CGFloat
    ) -> CGFloat {
        let center = viewportLength / 2
        let scaledMin = center + (imageMin - center) * scale
        let scaledMax = center + (imageMax - center) * scale
        if scaledMax - scaledMin <= viewportLength { return -(scaledMin + scaledMax - viewportLength) / 2 }
        return min(-scaledMin, max(viewportLength - scaledMax, value))
    }
}

/// Receives wheel events without covering the SwiftUI drag gestures used by masks and crop.
struct PhotoWheelCapture: NSViewRepresentable {
    var onZoom: (CGFloat, Bool, CGPoint, CGSize) -> Void
    var onPan: (CGSize, CGSize) -> Void
    var canPan: Bool

    func makeNSView(context: Context) -> PhotoWheelCaptureView {
        let view = PhotoWheelCaptureView()
        view.onZoom = onZoom
        view.onPan = onPan
        view.canPan = canPan
        return view
    }

    func updateNSView(_ view: PhotoWheelCaptureView, context: Context) {
        view.onZoom = onZoom
        view.onPan = onPan
        view.canPan = canPan
    }

    static func dismantleNSView(_ view: PhotoWheelCaptureView, coordinator: ()) {
        view.stopMonitoring()
    }
}

final class PhotoWheelCaptureView: NSView {
    var onZoom: ((CGFloat, Bool, CGPoint, CGSize) -> Void)?
    var onPan: ((CGSize, CGSize) -> Void)?
    var canPan = false
    private var monitor: Any?
    private var lastPanPoint: CGPoint?
    private var panButton: Int?

    override var isFlipped: Bool { true }

    // Let masks, crop handles, and the photo receive all ordinary mouse gestures.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [
            .scrollWheel, .otherMouseDown, .otherMouseDragged, .otherMouseUp,
            .leftMouseDown, .leftMouseDragged, .leftMouseUp
        ]) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        lastPanPoint = nil
        panButton = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window else { return event }
        let point = convert(event.locationInWindow, from: nil)

        switch event.type {
        case .scrollWheel:
            guard bounds.contains(point), event.scrollingDeltaY != 0 else { return event }
            onZoom?(event.scrollingDeltaY, event.hasPreciseScrollingDeltas, point, bounds.size)
            return nil
        case .otherMouseDown:
            guard canPan, event.buttonNumber == 2, bounds.contains(point) else { return event }
            lastPanPoint = point
            panButton = 2
            return nil
        case .leftMouseDown:
            guard canPan, event.modifierFlags.contains(.command), bounds.contains(point) else { return event }
            lastPanPoint = point
            panButton = 0
            return nil
        case .otherMouseDragged, .leftMouseDragged:
            guard event.buttonNumber == panButton, let previous = lastPanPoint else { return event }
            onPan?(CGSize(width: point.x - previous.x, height: point.y - previous.y), bounds.size)
            lastPanPoint = point
            return nil
        case .otherMouseUp, .leftMouseUp:
            guard event.buttonNumber == panButton, lastPanPoint != nil else { return event }
            lastPanPoint = nil
            panButton = nil
            return nil
        default:
            return event
        }
    }
}
