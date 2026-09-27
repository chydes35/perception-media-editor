import CoreGraphics
import Testing
@testable import PerceptionEditor

struct PhotoZoomViewportTests {
    private let viewport = CGSize(width: 900, height: 600)
    private let image = CGSize(width: 1800, height: 1200)

    @Test func wheelZoomIsContinuousAndKeepsThePointUnderThePointer() {
        var zoom = PhotoZoomViewport()
        let pointer = CGPoint(x: 500, y: 320)
        let imagePoint = imagePoint(at: pointer, zoom: zoom)

        zoom.zoom(by: 1, precise: false, at: pointer, viewport: viewport, image: image)
        #expect(zoom.scale > 1 && zoom.scale < 1.3)
        let after = screenPoint(for: imagePoint, zoom: zoom)
        #expect(abs(after.x - pointer.x) < 0.001)
        #expect(abs(after.y - pointer.y) < 0.001)

        zoom.zoom(by: -1, precise: false, at: pointer, viewport: viewport, image: image)
        #expect(zoom.isFitted)
    }

    @Test func zoomOutAndPanStayBoundedAndFitResetsTheView() {
        var zoom = PhotoZoomViewport()
        let middle = CGPoint(x: 450, y: 300)
        zoom.zoom(by: -40, precise: false, at: middle, viewport: viewport, image: image)
        #expect(zoom.scale < 0.1)
        #expect(abs(zoom.offset.width) < 0.001 && abs(zoom.offset.height) < 0.001)

        zoom.zoom(by: 80, precise: false, at: middle, viewport: viewport, image: image)
        zoom.pan(by: CGSize(width: -100_000, height: 100_000), viewport: viewport, image: image)
        let frame = MaskEditingLayer.fittedFrame(in: viewport, image: image)
        let left = viewport.width / 2 + (frame.minX - viewport.width / 2) * zoom.scale + zoom.offset.width
        let bottom = viewport.height / 2 + (frame.maxY - viewport.height / 2) * zoom.scale + zoom.offset.height
        #expect(left <= 0.001)
        #expect(bottom >= viewport.height - 0.001)

        zoom.reset()
        #expect(zoom.isFitted)
    }

    @Test func pixelViewTransitionKeepsItsCenter() {
        var zoom = PhotoZoomViewport()
        let center = CGPoint(x: 0.75, y: 0.4)
        zoom.matchPixelView(
            center: center, fullImage: CGSize(width: 6000, height: 4000),
            displayScale: 2, viewport: viewport, preview: image
        )
        #expect(zoom.scale > 3)
        let point = screenPoint(for: center, zoom: zoom)
        #expect(abs(point.x - viewport.width / 2) < 0.001)
        #expect(abs(point.y - viewport.height / 2) < 0.001)
    }

    private func imagePoint(at screen: CGPoint, zoom: PhotoZoomViewport) -> CGPoint {
        let frame = MaskEditingLayer.fittedFrame(in: viewport, image: image)
        return CGPoint(x: (screen.x - frame.minX) / frame.width, y: (screen.y - frame.minY) / frame.height)
    }

    private func screenPoint(for normalized: CGPoint, zoom: PhotoZoomViewport) -> CGPoint {
        let frame = MaskEditingLayer.fittedFrame(in: viewport, image: image)
        let base = CGPoint(x: frame.minX + normalized.x * frame.width, y: frame.minY + normalized.y * frame.height)
        return CGPoint(
            x: viewport.width / 2 + (base.x - viewport.width / 2) * zoom.scale + zoom.offset.width,
            y: viewport.height / 2 + (base.y - viewport.height / 2) * zoom.scale + zoom.offset.height
        )
    }
}
