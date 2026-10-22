import CoreGraphics
import Foundation
import Testing
@testable import PerceptionEditor

struct CropLayoutTests {
    /// The crop box is drawn over the fitted photo, so its fractions are fractions of the photo.
    @MainActor @Test func cropBoxCoversThePhotoNotTheLetterboxedCanvas() throws {
        // A 2:3 portrait photo in a wide canvas leaves empty bars left and right.
        let canvas = CGSize(width: 675, height: 565)
        let photo = CGSize(width: 2730, height: 4096)
        let frame = try #require(PhotoComparisonView.fittedFrame(in: canvas, image: photo))

        #expect(frame.width < canvas.width - 56, "bars remain beside a portrait photo")
        #expect(abs(frame.midX - canvas.width / 2) < 0.5 && abs(frame.midY - canvas.height / 2) < 0.5)
        #expect(abs(frame.width / frame.height - photo.width / photo.height) < 0.001, "the aspect ratio is kept")

        // A box over the right half of the visible photo is the right half of the photo.
        let rightHalf = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        let store = MainActorBox()
        let stored = store.cropRect(fromDisplay: rightHalf)
        #expect(stored?.x == 0.5 && stored?.width == 0.5 && stored?.y == 0 && stored?.height == 1)

        // The overlay's own edge is the photo's edge.
        let edge = try #require(PhotoComparisonView.normalizedPoint(CGPoint(x: frame.maxX - 0.5, y: frame.midY), in: canvas, image: photo))
        #expect(edge.x > 0.99)
    }

    @Test func fittedFrameMatchesTheClickMapping() throws {
        let canvas = CGSize(width: 456, height: 256)
        let photo = CGSize(width: 200, height: 100)
        let frame = try #require(PhotoComparisonView.fittedFrame(in: canvas, image: photo))
        #expect(frame == CGRect(x: 28, y: 28, width: 400, height: 200))
        #expect(PhotoComparisonView.fittedFrame(in: CGSize(width: 40, height: 40), image: photo) == nil)
    }
}

@MainActor
private struct MainActorBox {
    func cropRect(fromDisplay rect: CGRect) -> CropRect? {
        let defaults = UserDefaults(suiteName: "pme-crop-\(UUID())")!
        let store = EditorStore(presetRepository: UserPresetRepository(defaults: defaults))
        let asset = MediaAsset(url: URL(fileURLWithPath: "/Volumes/Test/crop.jpg"))
        store.project.media = [asset]
        store.select(asset)
        store.updateCropRectFromDisplay(rect)
        return store.selectedAdjustments.cropRect
    }
}
