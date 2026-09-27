import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO

// MARK: - Model

/// A position in the original image, 0–1 from its top-left corner. Masks are stored in the
/// original image's coordinates (before rotation, straighten, and crop), so they stay on the
/// same part of the picture when the crop changes.
struct NormalizedPoint: Codable, Hashable, Sendable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    init(_ point: CGPoint) {
        self.init(x: Double(point.x), y: Double(point.y))
    }

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

struct BrushStroke: Codable, Hashable, Sendable {
    var points: [NormalizedPoint]
    /// Brush diameter as a fraction of the image's longer side.
    var size: Double
    /// 0 is a hard edge, 1 fades from the center out.
    var feather: Double
    var isErase: Bool

    init(points: [NormalizedPoint], size: Double, feather: Double, isErase: Bool = false) {
        self.points = points
        self.size = size
        self.feather = feather
        self.isErase = isErase
    }
}

/// A Vision selection in the oriented source photo, with optional hand-painted corrections.
/// The grayscale PNG is bounded to 3072 pixels on its longest side so projects stay portable.
struct SubjectMask: Codable, Hashable, Sendable {
    var png: Data
    var strokes: [BrushStroke] = []
}

enum MaskShape: Codable, Hashable, Sendable {
    /// Full effect at `start`, fading to none at `end`, and extending past both.
    case linear(start: NormalizedPoint, end: NormalizedPoint)
    /// An ellipse. Radii are fractions of the image's longer side, `rotation` is degrees
    /// clockwise, and `feather` is how much of the radius fades out at the edge (0–1).
    case radial(center: NormalizedPoint, radiusX: Double, radiusY: Double, rotation: Double, feather: Double)
    case brush(strokes: [BrushStroke])
    case subject(SubjectMask)

    var isGradient: Bool {
        switch self {
        case .linear, .radial: true
        case .brush, .subject: false
        }
    }

    var kindName: String {
        switch self {
        case .linear: "Linear Gradient"
        case .radial: "Radial Gradient"
        case .brush: "Brush"
        case .subject: "Subject"
        }
    }
}

/// Adjustments applied only inside a mask. They use the same filters as the global sliders.
struct MaskAdjustments: Codable, Hashable, Sendable {
    var exposure = 0.0
    var contrast = 0.0
    var highlights = 0.0
    var shadows = 0.0
    var temperature = 0.0
    var tint = 0.0
    var saturation = 0.0
    var sharpness = 0.0

    var isNeutral: Bool { self == MaskAdjustments() }

    private enum CodingKeys: String, CodingKey {
        case exposure, contrast, highlights, shadows, temperature, tint, saturation, sharpness
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        exposure = try container.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        contrast = try container.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        highlights = try container.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        shadows = try container.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? 0
        tint = try container.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        saturation = try container.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        sharpness = try container.decodeIfPresent(Double.self, forKey: .sharpness) ?? 0
    }
}

struct LocalMask: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String?
    var shape: MaskShape
    var invert: Bool
    /// How strongly the mask applies, 0–1.
    var amount: Double
    var isEnabled: Bool
    var adjustments: MaskAdjustments

    init(
        id: UUID = UUID(),
        name: String? = nil,
        shape: MaskShape,
        invert: Bool = false,
        amount: Double = 1,
        isEnabled: Bool = true,
        adjustments: MaskAdjustments = MaskAdjustments()
    ) {
        self.id = id
        self.name = name
        self.shape = shape
        self.invert = invert
        self.amount = amount
        self.isEnabled = isEnabled
        self.adjustments = adjustments
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, shape, invert, amount, isEnabled, adjustments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        shape = try container.decode(MaskShape.self, forKey: .shape)
        invert = try container.decodeIfPresent(Bool.self, forKey: .invert) ?? false
        amount = try container.decodeIfPresent(Double.self, forKey: .amount) ?? 1
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        adjustments = try container.decodeIfPresent(MaskAdjustments.self, forKey: .adjustments) ?? MaskAdjustments()
    }

    /// Whether this mask changes anything when rendered.
    var isActive: Bool {
        isEnabled && amount > 0 && !adjustments.isNeutral
    }

    /// A copy with a fresh identity, for pasting onto another photo.
    func duplicated() -> LocalMask {
        LocalMask(
            name: name, shape: shape, invert: invert, amount: amount,
            isEnabled: isEnabled, adjustments: adjustments
        )
    }
}

// MARK: - Rendering

/// Builds the grayscale image for a mask: white where the mask applies fully, black where it
/// does not. The image covers `extent` (the original image, before any geometry) and holds raw
/// values, so it is not color managed.
enum MaskRenderer {
    static func image(for mask: LocalMask, extent: CGRect) -> CIImage {
        var image = baseImage(for: mask.shape, extent: extent)

        if mask.invert {
            image = image.applyingFilter("CIColorInvert")
        }
        if mask.amount < 1 {
            let amount = CGFloat(max(0, mask.amount))
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: amount, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: amount, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: amount, w: 0)
            ])
        }
        return image.cropped(to: extent)
    }

    private static func baseImage(for shape: MaskShape, extent: CGRect) -> CIImage {
        switch shape {
        case .linear(let start, let end):
            return linear(start: start, end: end, extent: extent)
        case .radial(let center, let radiusX, let radiusY, let rotation, let feather):
            return radial(center: center, radiusX: radiusX, radiusY: radiusY, rotation: rotation, feather: feather, extent: extent)
        case .brush(let strokes):
            return BrushRasterizer.image(strokes: strokes, extent: extent)
        case .subject(let subject):
            return SubjectMaskRenderer.image(subject, extent: extent)
        }
    }

    /// Core Image measures from the bottom-left corner.
    private static func pixel(_ point: NormalizedPoint, in extent: CGRect) -> CGPoint {
        CGPoint(x: extent.minX + point.x * extent.width, y: extent.minY + (1 - point.y) * extent.height)
    }

    /// A smoothstep lookup, so gradients ease in and out instead of fading in a straight line.
    private static let easingData: Data = {
        var values = [Float]()
        for i in 0 ..< 256 {
            let t = Float(i) / 255
            let eased = t * t * (3 - 2 * t)
            values += [eased, eased, eased]
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }()

    /// Mask values are raw weights, not colors. The easing runs in the working space itself so
    /// it acts on those values as they are; the ordinary tone-curve filter would treat them as
    /// gamma-encoded color and bend the midpoint.
    private static let workingSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    private static func ease(_ image: CIImage) -> CIImage {
        let filter = CIFilter.colorCurves()
        filter.inputImage = image
        filter.curvesData = easingData
        filter.curvesDomain = CIVector(x: 0, y: 1)
        filter.colorSpace = workingSpace
        return filter.outputImage ?? image
    }

    private static func linear(start: NormalizedPoint, end: NormalizedPoint, extent: CGRect) -> CIImage {
        let from = pixel(start, in: extent)
        var to = pixel(end, in: extent)
        if hypot(to.x - from.x, to.y - from.y) < 1 {
            to = CGPoint(x: from.x, y: from.y - 1)   // a zero-length gradient is a hard edge
        }
        let filter = CIFilter.linearGradient()
        filter.point0 = from
        filter.point1 = to
        filter.color0 = CIColor(red: 1, green: 1, blue: 1)
        filter.color1 = CIColor(red: 0, green: 0, blue: 0)
        return ease(filter.outputImage ?? CIImage(color: .black)).cropped(to: extent)
    }

    private static func radial(
        center: NormalizedPoint,
        radiusX: Double,
        radiusY: Double,
        rotation: Double,
        feather: Double,
        extent: CGRect
    ) -> CIImage {
        let longSide = max(extent.width, extent.height)
        let rx = max(1, CGFloat(radiusX) * longSide)
        let ry = max(1, CGFloat(radiusY) * longSide)
        let inner = min(0.999, max(0, 1 - CGFloat(feather)))

        // A unit circle at the origin, stretched, turned, and moved into place.
        let filter = CIFilter.radialGradient()
        filter.center = .zero
        filter.radius0 = Float(inner)
        filter.radius1 = 1
        filter.color0 = CIColor(red: 1, green: 1, blue: 1)
        filter.color1 = CIColor(red: 0, green: 0, blue: 0)

        let place = CGAffineTransform(scaleX: rx, y: ry)
            .concatenating(CGAffineTransform(rotationAngle: -CGFloat(rotation) * .pi / 180))
        let target = pixel(center, in: extent)
        let transform = place.concatenating(CGAffineTransform(translationX: target.x, y: target.y))

        let gradient = (filter.outputImage ?? CIImage(color: .black)).transformed(by: transform)
        return ease(gradient).cropped(to: extent)
    }
}

enum SubjectMaskRenderer {
    static func image(_ subject: SubjectMask, extent: CGRect) -> CIImage {
        guard let base = SubjectBaseMaskCache.shared.image(for: subject.png),
              extent.width > 0, extent.height > 0
        else { return CIImage(color: .black).cropped(to: extent) }

        let longSide = max(extent.width, extent.height)
        let scale = min(1, BrushRasterizer.maximumDimension / longSide)
        let width = max(1, Int((extent.width * scale).rounded(.up)))
        let height = max(1, Int((extent.height * scale).rounded(.up)))
        let raster: CGImage
        if subject.strokes.isEmpty {
            raster = base
        } else {
            raster = BrushRasterizer.raster(
                subject.strokes, width: width, height: height,
                baseImage: base, baseKey: subject.png
            ) ?? base
        }
        return CIImage(cgImage: raster, options: [.colorSpace: NSNull()])
            .transformed(by: CGAffineTransform(
                scaleX: extent.width / CGFloat(raster.width),
                y: extent.height / CGFloat(raster.height)
            ))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }
}

/// Decodes each selected PNG once; slider drags reuse its CGImage while brush corrections use
/// BrushMaskCache's incremental rasterization. Bounded to three photos/subjects on an 8 GB Mac.
private final class SubjectBaseMaskCache: @unchecked Sendable {
    static let shared = SubjectBaseMaskCache()
    private let lock = NSLock()
    private var entries: [(png: Data, image: CGImage)] = []

    func image(for png: Data) -> CGImage? {
        lock.lock()
        if let index = entries.firstIndex(where: { $0.png == png }) {
            let entry = entries.remove(at: index)
            entries.append(entry)
            lock.unlock()
            return entry.image
        }
        lock.unlock()

        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        lock.lock()
        entries.append((png, image))
        if entries.count > 3 { entries.removeFirst(entries.count - 3) }
        lock.unlock()
        return image
    }
}

/// Paints brush strokes into a grayscale bitmap.
enum BrushRasterizer {
    /// Masks are drawn at up to this many pixels on the long side and scaled to fit the image,
    /// which keeps a 24 MP photo's brush mask small. Brush edges are soft, so little is lost.
    static let maximumDimension: CGFloat = 3072

    static func image(strokes: [BrushStroke], extent: CGRect) -> CIImage {
        guard extent.width >= 1, extent.height >= 1 else { return CIImage(color: .black).cropped(to: extent) }

        let longSide = max(extent.width, extent.height)
        let scale = min(1, maximumDimension / longSide)
        let width = max(1, Int((extent.width * scale).rounded(.up)))
        let height = max(1, Int((extent.height * scale).rounded(.up)))

        guard let cgImage = raster(strokes, width: width, height: height) else {
            return CIImage(color: .black).cropped(to: extent)
        }

        let raw = CIImage(cgImage: cgImage, options: [.colorSpace: NSNull()])
        return raw
            .transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(width), y: extent.height / CGFloat(height)))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }

    /// The raster for `strokes`. It is reused when nothing changed and continued when strokes
    /// were only added, or points were only added to the last stroke, which is what painting
    /// does. Only the new dabs are drawn, so painting stays fast however many strokes exist.
    static func raster(
        _ strokes: [BrushStroke], width: Int, height: Int,
        baseImage: CGImage? = nil, baseKey: Data? = nil
    ) -> CGImage? {
        let cache = BrushMaskCache.shared
        if let exact = cache.exact(strokes, width: width, height: height, baseKey: baseKey) { return exact }

        let base = cache.continuation(for: strokes, width: width, height: height, baseKey: baseKey)
            ?? baseImage.map { Base(image: $0, strokeIndex: 0, pointCount: 0) }
        guard let image = rasterize(strokes, width: width, height: height, continuing: base) else { return nil }
        cache.store(image, for: strokes, width: width, height: height, baseKey: baseKey)
        return image
    }

    /// A finished raster and where in the strokes it stops.
    struct Base {
        var image: CGImage
        /// The stroke that was being drawn when the raster was made.
        var strokeIndex: Int
        /// How many of that stroke's points were drawn.
        var pointCount: Int
    }

    /// Strokes are drawn as overlapping soft dabs. Painting keeps the lightest value and erasing
    /// the darkest, so the dabs of one stroke merge into a single even stroke instead of
    /// stacking up and hardening the edge.
    static func rasterize(_ strokes: [BrushStroke], width: Int, height: Int, continuing base: Base? = nil) -> CGImage? {
        let space = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        let full = CGRect(x: 0, y: 0, width: width, height: height)
        if let base {
            context.draw(base.image, in: full)
        } else {
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(full)
        }

        let longSide = CGFloat(max(width, height))
        let firstStroke = base?.strokeIndex ?? 0
        for index in firstStroke ..< strokes.count {
            let stroke = strokes[index]
            guard !stroke.points.isEmpty else { continue }
            // Continue the resumed stroke from its last drawn point, so the line stays joined.
            let startPoint = (index == firstStroke) ? max(0, (base?.pointCount ?? 1) - 1) : 0
            draw(stroke, from: startPoint, in: context, width: width, height: height, longSide: longSide, space: space)
        }
        return context.makeImage()
    }

    private static func draw(
        _ stroke: BrushStroke, from startIndex: Int, in context: CGContext,
        width: Int, height: Int, longSide: CGFloat, space: CGColorSpace
    ) {
        let radius = max(0.5, CGFloat(stroke.size) * longSide / 2)
        let inner = min(0.999, max(0, 1 - CGFloat(stroke.feather)))
        // Painting fades white to black; erasing fades black to white.
        let colors: [CGFloat] = stroke.isErase ? [0, 1, 0, 1, 1, 1] : [1, 1, 1, 1, 0, 1]
        guard let gradient = CGGradient(
            colorSpace: space, colorComponents: colors, locations: [0, inner, 1], count: 3
        ) else { return }
        context.setBlendMode(stroke.isErase ? .darken : .lighten)

        let spacing = max(1, radius * 0.2)
        var previous: CGPoint?
        for normalized in stroke.points[startIndex...] {
            let point = CGPoint(x: normalized.x * CGFloat(width), y: (1 - normalized.y) * CGFloat(height))
            if let start = previous {
                let distance = hypot(point.x - start.x, point.y - start.y)
                let steps = max(1, Int((distance / spacing).rounded(.up)))
                for step in 1 ... steps {
                    let t = CGFloat(step) / CGFloat(steps)
                    dab(context, gradient, radius, CGPoint(x: start.x + (point.x - start.x) * t, y: start.y + (point.y - start.y) * t))
                }
            } else {
                dab(context, gradient, radius, point)
            }
            previous = point
        }
    }

    private static func dab(_ context: CGContext, _ gradient: CGGradient, _ radius: CGFloat, _ center: CGPoint) {
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }
}

/// Keeps the last few brush rasters, so re-rendering the photo for an unrelated slider does not
/// paint every stroke again, and painting can continue from the previous raster.
private final class BrushMaskCache: @unchecked Sendable {
    static let shared = BrushMaskCache()

    private struct Entry {
        var strokes: [BrushStroke]
        var width: Int
        var height: Int
        var baseKey: Data?
        var image: CGImage
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private let limit = 6

    func exact(_ strokes: [BrushStroke], width: Int, height: Int, baseKey: Data? = nil) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = entries.firstIndex(where: {
            $0.width == width && $0.height == height && $0.baseKey == baseKey && $0.strokes == strokes
        }) else {
            return nil
        }
        let entry = entries.remove(at: index)
        entries.append(entry)
        return entry.image
    }

    /// A cached raster that `strokes` extends, preferring the one that covers the most.
    func continuation(for strokes: [BrushStroke], width: Int, height: Int, baseKey: Data? = nil) -> BrushRasterizer.Base? {
        lock.lock()
        defer { lock.unlock() }

        var best: (base: BrushRasterizer.Base, covered: Int)?
        for entry in entries where entry.width == width && entry.height == height && entry.baseKey == baseKey {
            guard let stop = Self.extensionPoint(of: entry.strokes, in: strokes) else { continue }
            let covered = stop.strokeIndex * 1_000_000 + stop.pointCount
            if covered > (best?.covered ?? -1) {
                best = (BrushRasterizer.Base(image: entry.image, strokeIndex: stop.strokeIndex, pointCount: stop.pointCount), covered)
            }
        }
        return best?.base
    }

    /// Where `cached` ends within `strokes`, if `strokes` only adds to it: every stroke but the
    /// last must match exactly, and the last may have gained points.
    private static func extensionPoint(of cached: [BrushStroke], in strokes: [BrushStroke]) -> (strokeIndex: Int, pointCount: Int)? {
        guard let last = cached.last, cached.count <= strokes.count else { return nil }
        let lastIndex = cached.count - 1
        for index in 0 ..< lastIndex where cached[index] != strokes[index] { return nil }

        let grown = strokes[lastIndex]
        guard last.size == grown.size, last.feather == grown.feather, last.isErase == grown.isErase,
              last.points.count <= grown.points.count,
              grown.points.prefix(last.points.count).elementsEqual(last.points)
        else { return nil }
        return (lastIndex, last.points.count)
    }

    func store(_ image: CGImage, for strokes: [BrushStroke], width: Int, height: Int, baseKey: Data? = nil) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(Entry(strokes: strokes, width: width, height: height, baseKey: baseKey, image: image))
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }
}
