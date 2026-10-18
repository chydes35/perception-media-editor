import AppKit
import SwiftUI
import Testing
@testable import PerceptionEditor

struct CropOverlayWiringTests {
    /// Renders the real view: the crop box border must sit on the fitted photo's edge, not the canvas edge.
    @MainActor @Test func cropBorderIsDrawnOnThePhotoEdgeInALetterboxedCanvas() throws {
        let canvas = CGSize(width: 675, height: 565)
        let photoSize = CGSize(width: 273, height: 410)
        let photo = NSImage(size: photoSize, flipped: false) { rect in
            NSColor.gray.setFill()
            rect.fill()
            return true
        }
        let defaults = UserDefaults(suiteName: "pme-wiring-\(UUID())")!
        let store = EditorStore(presetRepository: UserPresetRepository(defaults: defaults))
        var crop: CGRect? = CGRect(x: 0, y: 0, width: 1, height: 1)
        let binding = Binding<CGRect?>(get: { crop }, set: { crop = $0 })
        let view = PhotoComparisonView(
            original: photo, edited: photo, mode: .edited, isCropping: true,
            cropRect: binding, cropAspect: .original, onZoomRequest: nil
        )
        .environmentObject(store)
        .frame(width: canvas.width, height: canvas.height)

        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: canvas)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)

        let frame = try #require(PhotoComparisonView.fittedFrame(in: canvas, image: photoSize))
        let y = Int(canvas.height / 2) // vertical middle, away from the corner handles
        func isWhite(_ x: Int) -> Bool {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
            return c.redComponent > 0.9 && c.greenComponent > 0.9 && c.blueComponent > 0.9
        }
        let scale = CGFloat(rep.pixelsWide) / canvas.width
        let photoLeft = Int((frame.minX * scale).rounded())
        let nearPhotoEdge = (photoLeft - 3 ... photoLeft + 4).contains(where: isWhite)
        let nearCanvasEdge = (0 ... 4).contains(where: isWhite)
        #expect(nearPhotoEdge, "border should be on the photo's left edge")
        #expect(!nearCanvasEdge, "border should not be on the canvas edge")
    }
}
