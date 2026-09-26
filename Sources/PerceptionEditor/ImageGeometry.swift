import CoreGraphics
import Foundation

/// How a photo's original pixels map to the finished picture after rotation, straighten, and
/// crop, and back. Masks are stored in original-image coordinates but drawn and dragged on the
/// finished picture, so every position on screen goes through this.
///
/// It repeats the steps in `MediaColorRenderer` (which shares its crop math) and is checked
/// against real renders in the tests.
struct ImageGeometry: Equatable {
    let sourceSize: CGSize
    let finishedSize: CGSize
    /// Original pixels to finished pixels, both measured from the bottom-left corner as Core Image does.
    private let forward: CGAffineTransform

    init(sourceSize: CGSize, adjustments: PhotoAdjustments) {
        self.sourceSize = sourceSize
        var transform = CGAffineTransform.identity
        var rect = CGRect(origin: .zero, size: sourceSize)

        func apply(_ step: CGAffineTransform) {
            transform = transform.concatenating(step)
            rect = rect.applying(step)
            let shift = CGAffineTransform(translationX: -rect.minX, y: -rect.minY)
            transform = transform.concatenating(shift)
            rect = rect.applying(shift)
        }

        if adjustments.rotationQuarterTurns != 0 {
            apply(CGAffineTransform(rotationAngle: CGFloat(adjustments.rotationQuarterTurns) * .pi / 2))
        }
        if let degrees = adjustments.straightenDegrees, abs(degrees) > 0.001 {
            apply(CGAffineTransform(rotationAngle: CGFloat(degrees) * .pi / 180))
        }
        if let area = Self.cropArea(in: rect, aspect: adjustments.cropAspect, rect: adjustments.cropRect) {
            let shift = CGAffineTransform(translationX: -area.minX, y: -area.minY)
            transform = transform.concatenating(shift)
            rect = CGRect(origin: .zero, size: area.size)
        }

        forward = transform
        finishedSize = rect.size
    }

    /// The area a crop keeps, in the coordinates of `extent`, or nil when nothing is cropped.
    static func cropArea(in extent: CGRect, aspect: CropAspect, rect: CropRect?) -> CGRect? {
        if let rect {
            return CGRect(
                x: extent.minX + extent.width * rect.x,
                y: extent.minY + extent.height * rect.y,
                width: extent.width * rect.width,
                height: extent.height * rect.height
            ).integral
        }

        guard let ratio = aspect.ratio else { return nil }
        let currentRatio = extent.width / extent.height
        let area: CGRect
        if currentRatio > ratio {
            let width = extent.height * ratio
            area = CGRect(x: extent.midX - width / 2, y: extent.minY, width: width, height: extent.height)
        } else {
            let height = extent.width / ratio
            area = CGRect(x: extent.minX, y: extent.midY - height / 2, width: extent.width, height: height)
        }
        return area.integral
    }

    /// Where a point in the original (0–1 from its top-left) lands on the finished picture
    /// (0–1 from its top-left). It can fall outside 0–1 when the point was cropped away.
    func finished(fromSource point: NormalizedPoint) -> NormalizedPoint {
        let pixel = CGPoint(x: point.x * sourceSize.width, y: (1 - point.y) * sourceSize.height)
        let mapped = pixel.applying(forward)
        return NormalizedPoint(x: mapped.x / finishedSize.width, y: 1 - mapped.y / finishedSize.height)
    }

    /// Where a point on the finished picture is in the original.
    func source(fromFinished point: NormalizedPoint) -> NormalizedPoint {
        let pixel = CGPoint(x: point.x * finishedSize.width, y: (1 - point.y) * finishedSize.height)
        let mapped = pixel.applying(forward.inverted())
        return NormalizedPoint(x: mapped.x / sourceSize.width, y: 1 - mapped.y / sourceSize.height)
    }

    /// One pixel of the original is one pixel of the finished picture, so sizes given as a fraction
    /// of the original's longer side are `longSide` finished pixels.
    var longSide: CGFloat { max(sourceSize.width, sourceSize.height) }
}
