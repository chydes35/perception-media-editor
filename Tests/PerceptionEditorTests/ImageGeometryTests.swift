import CoreImage
import Foundation
import Testing
@testable import PerceptionEditor

struct ImageGeometryTests {
    private let size = CGSize(width: 600, height: 400)
    private let context = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])

    @Test func withNoEditsPositionsAreUnchanged() {
        let geometry = ImageGeometry(sourceSize: size, adjustments: PhotoAdjustments())
        #expect(geometry.finishedSize == size)
        let point = NormalizedPoint(x: 0.3, y: 0.7)
        let mapped = geometry.finished(fromSource: point)
        #expect(abs(mapped.x - 0.3) < 1e-9 && abs(mapped.y - 0.7) < 1e-9)
    }

    @Test func aQuarterTurnSwapsTheSizeAndMovesTheTopEdge() {
        var adjustments = PhotoAdjustments()
        adjustments.rotationQuarterTurns = 1
        let geometry = ImageGeometry(sourceSize: size, adjustments: adjustments)

        #expect(abs(geometry.finishedSize.width - 400) < 1e-6 && abs(geometry.finishedSize.height - 600) < 1e-6)
        // The top-center of the original ends up on a side edge, at the middle of that edge.
        let top = geometry.finished(fromSource: NormalizedPoint(x: 0.5, y: 0))
        #expect(abs(top.y - 0.5) < 1e-6)
        #expect(top.x < 1e-6 || top.x > 1 - 1e-6)
    }

    @Test func mappingThereAndBackReturnsTheStartingPoint() {
        var adjustments = PhotoAdjustments()
        adjustments.rotationQuarterTurns = 3
        adjustments.straightenDegrees = -4.5
        adjustments.cropRect = CropRect(x: 0.1, y: 0.15, width: 0.7, height: 0.6)
        let geometry = ImageGeometry(sourceSize: size, adjustments: adjustments)

        for (x, y) in [(0.5, 0.5), (0.2, 0.3), (0.8, 0.9), (0.0, 0.0), (1.0, 1.0)] {
            let back = geometry.source(fromFinished: geometry.finished(fromSource: NormalizedPoint(x: x, y: y)))
            #expect(abs(back.x - x) < 1e-9 && abs(back.y - y) < 1e-9)
        }
    }

    // MARK: Against the real pipeline

    /// A photo that is black with one small white square at `point`.
    private func markedImage(at point: NormalizedPoint) -> CIImage {
        let black = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))
        let center = CGPoint(x: point.x * size.width, y: (1 - point.y) * size.height)
        let mark = CIImage(color: .white).cropped(to: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8))
        return mark.composited(over: black)
    }

    /// The center of the white square in a rendered image, from its top-left, in 0–1.
    private func markPosition(in image: CIImage) -> NormalizedPoint? {
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        context.render(
            image, toBitmap: &pixels, rowBytes: width * 4,
            bounds: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
        )
        var sumX = 0.0, sumY = 0.0, count = 0.0
        for y in 0 ..< height {
            for x in 0 ..< width where pixels[(y * width + x) * 4 + 1] > 200 && pixels[(y * width + x) * 4 + 3] > 200 {
                sumX += Double(x) + 0.5
                sumY += Double(y) + 0.5   // bitmap rows run top to bottom
                count += 1
            }
        }
        guard count > 8 else { return nil }
        return NormalizedPoint(x: sumX / count / Double(width), y: sumY / count / Double(height))
    }

    private func check(_ adjustments: PhotoAdjustments, source point: NormalizedPoint, _ label: String) throws {
        let rendered = MediaColorRenderer.render(markedImage(at: point), adjustments: adjustments, includesGeometry: true)
        let geometry = ImageGeometry(sourceSize: size, adjustments: adjustments)
        let predicted = geometry.finished(fromSource: point)
        let found = try #require(markPosition(in: rendered), "\(label): the mark is not in the picture")

        let tolerance = 2.5   // pixels
        let dx = abs(found.x - predicted.x) * Double(geometry.finishedSize.width)
        let dy = abs(found.y - predicted.y) * Double(geometry.finishedSize.height)
        #expect(dx < tolerance && dy < tolerance, "\(label): predicted (\(predicted.x), \(predicted.y)), found (\(found.x), \(found.y))")
        #expect(abs(Double(rendered.extent.width) - geometry.finishedSize.width) <= 1, "\(label): width")
        #expect(abs(Double(rendered.extent.height) - geometry.finishedSize.height) <= 1, "\(label): height")
    }

    @Test func theMappingMatchesTheRenderedPictureForEveryKindOfEdit() throws {
        let point = NormalizedPoint(x: 0.3, y: 0.35)

        try check(PhotoAdjustments(), source: point, "no edits")

        for turns in 1 ... 3 {
            var a = PhotoAdjustments(); a.rotationQuarterTurns = turns
            try check(a, source: point, "\(turns) quarter turn(s)")
        }

        var straight = PhotoAdjustments(); straight.straightenDegrees = 7
        try check(straight, source: point, "straighten 7°")
        straight.straightenDegrees = -12
        try check(straight, source: point, "straighten -12°")

        var crop = PhotoAdjustments(); crop.cropRect = CropRect(x: 0.15, y: 0.2, width: 0.6, height: 0.7)
        try check(crop, source: point, "free crop")

        for aspect in [CropAspect.square, .portrait, .widescreen, .vertical] {
            var a = PhotoAdjustments(); a.cropAspect = aspect
            try check(a, source: NormalizedPoint(x: 0.5, y: 0.45), "\(aspect.rawValue) crop")
        }

        var everything = PhotoAdjustments()
        everything.rotationQuarterTurns = 1
        everything.straightenDegrees = 5
        everything.cropRect = CropRect(x: 0.1, y: 0.1, width: 0.8, height: 0.75)
        try check(everything, source: NormalizedPoint(x: 0.5, y: 0.5), "rotate + straighten + crop")
    }

    @Test func aPointCroppedAwayMapsOutsideThePicture() {
        var adjustments = PhotoAdjustments()
        adjustments.cropRect = CropRect(x: 0.5, y: 0, width: 0.5, height: 1)   // right half
        let geometry = ImageGeometry(sourceSize: size, adjustments: adjustments)

        let left = geometry.finished(fromSource: NormalizedPoint(x: 0.1, y: 0.5))
        #expect(left.x < 0, "the left part of the original is off the finished picture")
        let right = geometry.finished(fromSource: NormalizedPoint(x: 0.75, y: 0.5))
        #expect(abs(right.x - 0.5) < 1e-6)
    }
}
