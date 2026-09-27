import CoreGraphics
import CoreImage
import Foundation

enum RetouchKind: String, Codable, Sendable {
    case heal
    case clone

    var title: String { self == .heal ? "Heal" : "Clone" }
}

/// A repair painted in the original photo's coordinates. The source follows the complete
/// target path at a constant offset, and can be moved after the stroke is drawn.
struct RetouchStroke: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var kind: RetouchKind
    var points: [NormalizedPoint]
    var source: NormalizedPoint
    /// Diameter as a fraction of the longer image side.
    var size: Double
    var feather: Double
    var opacity: Double
    var isEnabled: Bool

    init(id: UUID = UUID(), kind: RetouchKind, points: [NormalizedPoint], source: NormalizedPoint,
         size: Double, feather: Double, opacity: Double = 1, isEnabled: Bool = true) {
        self.id = id
        self.kind = kind
        self.points = points
        self.source = source
        self.size = size
        self.feather = feather
        self.opacity = opacity
        self.isEnabled = isEnabled
    }

    var target: NormalizedPoint? { points.first }

    /// Chooses a nearby patch that does not overlap the target brush where space permits.
    static func suggestedSource(for target: NormalizedPoint, size: Double, image: CGSize) -> NormalizedPoint {
        let long = max(image.width, image.height)
        guard long > 0 else { return target }
        let radius = max(0.005, size) * long * 1.5
        let insetX = min(0.49, size * long / image.width / 2)
        let insetY = min(0.49, size * long / image.height / 2)
        let candidates = [
            NormalizedPoint(x: target.x + radius / image.width, y: target.y - radius / image.height),
            NormalizedPoint(x: target.x - radius / image.width, y: target.y - radius / image.height),
            NormalizedPoint(x: target.x + radius / image.width, y: target.y + radius / image.height),
            NormalizedPoint(x: target.x - radius / image.width, y: target.y + radius / image.height)
        ]
        if let inside = candidates.first(where: { (insetX ... (1 - insetX)).contains($0.x) && (insetY ... (1 - insetY)).contains($0.y) }) {
            return inside
        }
        let candidate = candidates.max { a, b in
            min(a.x, 1 - a.x, a.y, 1 - a.y) < min(b.x, 1 - b.x, b.y, 1 - b.y)
        } ?? target
        return NormalizedPoint(x: min(1 - insetX, max(insetX, candidate.x)),
                               y: min(1 - insetY, max(insetY, candidate.y)))
    }
}

/// Applies repairs before the photo's geometry and global adjustments. All images stay lazy
/// Core Image graphs; no full-resolution pixel buffer is copied to the CPU.
enum RetouchRenderer {
    /// A compiled color kernel is immutable and Core Image can use it from concurrent render
    /// queues. The wrapper states that guarantee explicitly for Swift 6's strict concurrency.
    private final class ColorMatchKernel: @unchecked Sendable {
        let value = CIColorKernel(source: """
            kernel vec4 matchColor(__sample detail, __sample sourceLow, __sample targetLow) {
                return vec4(detail.rgb + targetLow.rgb - sourceLow.rgb, detail.a);
            }
            """)
    }
    private static let colorMatchKernel = ColorMatchKernel()

    static func apply(_ source: CIImage, strokes: [RetouchStroke]) -> CIImage {
        let extent = source.extent
        guard extent.width > 0, extent.height > 0 else { return source }
        var image = source
        for stroke in strokes where stroke.isEnabled && stroke.opacity > 0 && !stroke.points.isEmpty {
            let footprint = footprint(for: stroke, extent: extent)
            guard !footprint.isEmpty else { continue }
            let target = pixel(stroke.points[0], extent: extent)
            let sample = pixel(stroke.source, extent: extent)
            let dx = target.x - sample.x, dy = target.y - sample.y
            let sourcePatch = image.clampedToExtent().transformed(by: CGAffineTransform(translationX: dx, y: dy))
            let patch: CIImage
            if stroke.kind == .heal, let matchKernel = colorMatchKernel.value {
                let radius = max(2, stroke.size * max(extent.width, extent.height) * 1.2)
                let sourceLow = sourcePatch.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                let targetLow = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                patch = matchKernel.apply(extent: footprint, arguments: [sourcePatch, sourceLow, targetLow]) ?? sourcePatch.cropped(to: footprint)
            } else {
                patch = sourcePatch.cropped(to: footprint)
            }
            var mask = localMask(for: stroke, extent: extent, footprint: footprint)
            if stroke.opacity < 1 {
                let amount = CGFloat(max(0, min(1, stroke.opacity)))
                mask = mask.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: amount, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: amount, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: amount, w: 0)
                ])
            }
            let repairedPatch = patch.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: image.cropped(to: footprint), kCIInputMaskImageKey: mask
            ]).cropped(to: footprint)
            image = repairedPatch.composited(over: image).cropped(to: extent)
        }
        return image
    }

    private static func footprint(for stroke: RetouchStroke, extent: CGRect) -> CGRect {
        let pixels = stroke.points.map { pixel($0, extent: extent) }
        guard let first = pixels.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in pixels.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        let pad = max(1, stroke.size * max(extent.width, extent.height) / 2) + 2
        return CGRect(x: minX - pad, y: minY - pad,
                      width: maxX - minX + pad * 2, height: maxY - minY + pad * 2)
            .intersection(extent).integral
    }

    /// A small grayscale mask covering only the repair, instead of a 3072-pixel-long bitmap
    /// per spot. A hundred small spots then occupy about the same mask memory as one large brush.
    private static func localMask(for stroke: RetouchStroke, extent: CGRect, footprint: CGRect) -> CIImage {
        let long = max(extent.width, extent.height)
        let scale = min(1, BrushRasterizer.maximumDimension / long)
        let width = max(1, Int((footprint.width * scale).rounded(.up)))
        let height = max(1, Int((footprint.height * scale).rounded(.up)))
        let localPoints = stroke.points.map { point -> NormalizedPoint in
            let p = pixel(point, extent: extent)
            let x = Double((p.x - footprint.minX) / footprint.width)
            let y = Double((p.y - footprint.minY) / footprint.height)
            return NormalizedPoint(x: x, y: 1.0 - y)
        }
        let diameter = stroke.size * long / max(footprint.width, footprint.height)
        let brush = BrushStroke(points: localPoints, size: diameter, feather: stroke.feather)
        guard let raster = BrushRasterizer.rasterize([brush], width: width, height: height) else {
            return CIImage(color: .black).cropped(to: footprint)
        }
        return CIImage(cgImage: raster, options: [.colorSpace: NSNull()])
            .transformed(by: CGAffineTransform(scaleX: footprint.width / CGFloat(width),
                                               y: footprint.height / CGFloat(height)))
            .transformed(by: CGAffineTransform(translationX: footprint.minX, y: footprint.minY))
            .cropped(to: footprint)
    }

    private static func pixel(_ point: NormalizedPoint, extent: CGRect) -> CGPoint {
        CGPoint(x: extent.minX + point.x * extent.width,
                y: extent.minY + (1 - point.y) * extent.height)
    }
}
