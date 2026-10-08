import CoreImage
import Foundation
import Testing
@testable import PerceptionEditor

/// Reads mask values and pixels straight from Core Image.
private struct Sampler {
    let context = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// A raw (not color managed) 0–1 mask value at a point given from the image's top-left.
    func maskValue(_ image: CIImage, x: Double, y: Double) -> Double {
        let extent = image.extent
        let px = extent.minX + x * extent.width
        let py = extent.minY + (1 - y) * extent.height
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            image, toBitmap: &pixel, rowBytes: 4,
            bounds: CGRect(x: px.rounded(.down), y: py.rounded(.down), width: 1, height: 1),
            format: .RGBA8, colorSpace: nil
        )
        return Double(pixel[0]) / 255
    }

    /// The sRGB color at a point given from the image's top-left.
    func color(_ image: CIImage, x: Double, y: Double) -> (r: Int, g: Int, b: Int) {
        let extent = image.extent
        let px = extent.minX + min(extent.width - 1, x * extent.width)
        let py = extent.minY + min(extent.height - 1, (1 - y) * extent.height)
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            image, toBitmap: &pixel, rowBytes: 4,
            bounds: CGRect(x: px.rounded(.down), y: py.rounded(.down), width: 1, height: 1),
            format: .RGBA8, colorSpace: srgb
        )
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }
}

struct MaskModelTests {
    @Test func masksRoundTripThroughJSON() throws {
        let masks = [
            LocalMask(
                name: "Sky", shape: .linear(start: NormalizedPoint(x: 0.5, y: 0.1), end: NormalizedPoint(x: 0.5, y: 0.5)),
                invert: true, amount: 0.7, adjustments: MaskAdjustments()
            ),
            LocalMask(shape: .radial(center: NormalizedPoint(x: 0.3, y: 0.6), radiusX: 0.2, radiusY: 0.1, rotation: 30, feather: 0.4)),
            LocalMask(shape: .brush(strokes: [
                BrushStroke(points: [NormalizedPoint(x: 0.1, y: 0.1), NormalizedPoint(x: 0.2, y: 0.2)], size: 0.05, feather: 0.5),
                BrushStroke(points: [NormalizedPoint(x: 0.15, y: 0.15)], size: 0.02, feather: 0, isErase: true)
            ]))
        ]
        var adjustments = PhotoAdjustments()
        adjustments.masks = masks
        adjustments.masks[0].adjustments.exposure = -0.8

        let decoded = try JSONDecoder().decode(PhotoAdjustments.self, from: JSONEncoder().encode(adjustments))
        #expect(decoded == adjustments)
    }

    @Test func aPhotoWithoutMasksReadsBackWithNone() throws {
        let decoded = try JSONDecoder().decode(PhotoAdjustments.self, from: Data(#"{"exposure":0.2}"#.utf8))
        #expect(decoded.masks.isEmpty)
    }

    @Test func aMaskSavedWithFewerFieldsStillLoads() throws {
        let json = Data("""
        {"id":"6F4F5E2A-0F7B-4A0A-9E0D-0E9F6E6B1B11",
         "shape":{"linear":{"start":{"x":0.5,"y":0.1},"end":{"x":0.5,"y":0.6}}}}
        """.utf8)
        let mask = try JSONDecoder().decode(LocalMask.self, from: json)
        #expect(mask.isEnabled && !mask.invert && mask.amount == 1 && mask.adjustments.isNeutral)
        #expect(!mask.isActive, "no adjustments, nothing to render")
    }

    @Test func aMaskOnlyRendersWhenEnabledStrongEnoughAndAdjusting() {
        var mask = LocalMask(shape: .linear(start: NormalizedPoint(x: 0, y: 0), end: NormalizedPoint(x: 0, y: 1)))
        #expect(!mask.isActive)
        mask.adjustments.exposure = 1
        #expect(mask.isActive)
        mask.isEnabled = false
        #expect(!mask.isActive)
        mask.isEnabled = true
        mask.amount = 0
        #expect(!mask.isActive)
    }

    @Test func gradientsTravelBetweenPhotosButBrushesStayPut() {
        let gradient = LocalMask(
            shape: .linear(start: NormalizedPoint(x: 0.5, y: 0), end: NormalizedPoint(x: 0.5, y: 0.5)),
            adjustments: { var a = MaskAdjustments(); a.exposure = -1; return a }()
        )
        let brush = LocalMask(shape: .brush(strokes: [BrushStroke(points: [NormalizedPoint(x: 0.5, y: 0.5)], size: 0.1, feather: 0.5)]))
        var source = PhotoAdjustments(); source.masks = [gradient, brush]
        var target = PhotoAdjustments()
        let targetBrush = LocalMask(shape: .brush(strokes: [BrushStroke(points: [NormalizedPoint(x: 0.2, y: 0.2)], size: 0.1, feather: 0.5)]))
        target.masks = [targetBrush]

        let synced = target.applying(source, groups: [.masks])

        #expect(synced.masks.count == 2)
        #expect(synced.masks.contains(where: { $0.id == targetBrush.id }), "the target keeps its own brush")
        #expect(!synced.masks.contains(where: { $0.id == brush.id }), "the source's brush is not copied")
        let copied = synced.masks.first { $0.shape.isGradient }
        #expect(copied != nil && copied?.id != gradient.id, "a copied gradient gets its own identity")
        #expect(copied?.adjustments.exposure == -1)

        // Syncing twice replaces the copied gradient instead of stacking another.
        #expect(synced.applying(source, groups: [.masks]).masks.count == 2)
        // Saving a preset keeps the gradients only.
        #expect(source.containing([.masks]).masks.count == 1)
        #expect(source.editedGroups.contains(.masks))
    }

    @Test func aPhotoWithOnlyBrushStrokesHasNothingToSync() {
        var photo = PhotoAdjustments()
        photo.masks = [LocalMask(shape: .brush(strokes: [BrushStroke(points: [NormalizedPoint(x: 0.5, y: 0.5)], size: 0.1, feather: 0.5)]))]
        #expect(!photo.editedGroups.contains(.masks))
    }
}

struct MaskRenderingTests {
    private let sampler = Sampler()
    private let extent = CGRect(x: 0, y: 0, width: 400, height: 300)

    private func linearMask(invert: Bool = false, amount: Double = 1) -> LocalMask {
        LocalMask(
            shape: .linear(start: NormalizedPoint(x: 0.5, y: 0.2), end: NormalizedPoint(x: 0.5, y: 0.8)),
            invert: invert, amount: amount
        )
    }

    @Test func aLinearGradientIsFullAtTheStartAndNoneAtTheEnd() {
        let image = MaskRenderer.image(for: linearMask(), extent: extent)

        #expect(sampler.maskValue(image, x: 0.5, y: 0.05) > 0.98, "past the start it stays full")
        #expect(sampler.maskValue(image, x: 0.5, y: 0.2) > 0.97)
        #expect(abs(sampler.maskValue(image, x: 0.5, y: 0.5) - 0.5) < 0.05, "halfway is half")
        #expect(sampler.maskValue(image, x: 0.5, y: 0.8) < 0.03)
        #expect(sampler.maskValue(image, x: 0.5, y: 0.95) < 0.02, "past the end it stays empty")

        // It only varies along its own direction.
        #expect(abs(sampler.maskValue(image, x: 0.1, y: 0.5) - sampler.maskValue(image, x: 0.9, y: 0.5)) < 0.02)

        var last = 2.0
        for step in 0 ... 20 {
            let value = sampler.maskValue(image, x: 0.5, y: 0.2 + Double(step) * 0.03)
            #expect(value <= last + 0.01)
            last = value
        }
    }

    @Test func aGradientCanRunInAnyDirection() {
        let mask = LocalMask(shape: .linear(start: NormalizedPoint(x: 0.1, y: 0.5), end: NormalizedPoint(x: 0.9, y: 0.5)))
        let image = MaskRenderer.image(for: mask, extent: extent)
        #expect(sampler.maskValue(image, x: 0.05, y: 0.5) > 0.97)
        #expect(sampler.maskValue(image, x: 0.95, y: 0.5) < 0.03)
        #expect(abs(sampler.maskValue(image, x: 0.5, y: 0.1) - sampler.maskValue(image, x: 0.5, y: 0.9)) < 0.02)
    }

    @Test func invertingAndAmountScaleTheMask() {
        let normal = MaskRenderer.image(for: linearMask(), extent: extent)
        let inverted = MaskRenderer.image(for: linearMask(invert: true), extent: extent)
        let half = MaskRenderer.image(for: linearMask(amount: 0.5), extent: extent)

        for y in [0.1, 0.3, 0.5, 0.7, 0.9] {
            #expect(abs(sampler.maskValue(normal, x: 0.5, y: y) + sampler.maskValue(inverted, x: 0.5, y: y) - 1) < 0.02)
            #expect(abs(sampler.maskValue(half, x: 0.5, y: y) - sampler.maskValue(normal, x: 0.5, y: y) / 2) < 0.02)
        }
    }

    @Test func aZeroLengthGradientDoesNotBreak() {
        let point = NormalizedPoint(x: 0.5, y: 0.5)
        let image = MaskRenderer.image(for: LocalMask(shape: .linear(start: point, end: point)), extent: extent)
        #expect(sampler.maskValue(image, x: 0.5, y: 0.1) > 0.9)
        #expect(sampler.maskValue(image, x: 0.5, y: 0.9) < 0.1)
    }

    @Test func aRadialGradientIsAnEllipseInPixels() {
        // Radii are fractions of the long side (400 px): 0.3 → 120 px wide, 0.1 → 40 px tall.
        let mask = LocalMask(shape: .radial(
            center: NormalizedPoint(x: 0.5, y: 0.5), radiusX: 0.3, radiusY: 0.1, rotation: 0, feather: 0
        ))
        let image = MaskRenderer.image(for: mask, extent: extent)

        #expect(sampler.maskValue(image, x: 0.5, y: 0.5) > 0.98)
        #expect(sampler.maskValue(image, x: 0.5 + 100.0 / 400, y: 0.5) > 0.9, "100 px right is inside 120")
        #expect(sampler.maskValue(image, x: 0.5 + 140.0 / 400, y: 0.5) < 0.1, "140 px right is outside")
        #expect(sampler.maskValue(image, x: 0.5, y: 0.5 + 30.0 / 300) > 0.9, "30 px down is inside 40")
        #expect(sampler.maskValue(image, x: 0.5, y: 0.5 + 60.0 / 300) < 0.1, "60 px down is outside")
    }

    @Test func rotatingARadialGradientTurnsItClockwise() {
        let mask = LocalMask(shape: .radial(
            center: NormalizedPoint(x: 0.5, y: 0.5), radiusX: 0.3, radiusY: 0.05, rotation: 90, feather: 0
        ))
        let image = MaskRenderer.image(for: mask, extent: extent)

        #expect(sampler.maskValue(image, x: 0.5, y: 0.5 + 90.0 / 300) > 0.9, "turned a quarter, the long axis is vertical")
        #expect(sampler.maskValue(image, x: 0.5 + 90.0 / 400, y: 0.5) < 0.1)
    }

    @Test func featherSoftensTheEdgeOfARadialGradient() {
        func mask(_ feather: Double) -> CIImage {
            MaskRenderer.image(for: LocalMask(shape: .radial(
                center: NormalizedPoint(x: 0.5, y: 0.5), radiusX: 0.25, radiusY: 0.25, rotation: 0, feather: feather
            )), extent: extent)
        }
        let hard = mask(0), soft = mask(0.8)
        let nearEdge = 0.5 + 80.0 / 400   // 80 px from the center of a 100 px radius
        #expect(sampler.maskValue(hard, x: nearEdge, y: 0.5) > 0.95)
        #expect(sampler.maskValue(soft, x: nearEdge, y: 0.5) < 0.5)
        #expect(sampler.maskValue(soft, x: 0.5, y: 0.5) > 0.98, "the center is still full")
    }

    // MARK: Brush

    private func stroke(_ points: [(Double, Double)], size: Double = 0.2, feather: Double = 0, erase: Bool = false) -> BrushStroke {
        BrushStroke(points: points.map { NormalizedPoint(x: $0.0, y: $0.1) }, size: size, feather: feather, isErase: erase)
    }

    private func brush(_ strokes: [BrushStroke]) -> CIImage {
        MaskRenderer.image(for: LocalMask(shape: .brush(strokes: strokes)), extent: extent)
    }

    @Test func aBrushDabPaintsADiscOfTheBrushSize() {
        // Size 0.2 of the 400 px long side is an 80 px brush: a 40 px radius.
        let image = brush([stroke([(0.5, 0.5)])])
        #expect(sampler.maskValue(image, x: 0.5, y: 0.5) > 0.98)
        #expect(sampler.maskValue(image, x: 0.5 + 30.0 / 400, y: 0.5) > 0.95)
        #expect(sampler.maskValue(image, x: 0.5 + 55.0 / 400, y: 0.5) < 0.05)
        #expect(sampler.maskValue(image, x: 0.1, y: 0.1) < 0.02, "nothing painted elsewhere")
    }

    @Test func aFeatheredBrushFadesFromTheCenter() {
        let image = brush([stroke([(0.5, 0.5)], feather: 1)])
        let center = sampler.maskValue(image, x: 0.5, y: 0.5)
        let half = sampler.maskValue(image, x: 0.5 + 20.0 / 400, y: 0.5)
        let edge = sampler.maskValue(image, x: 0.5 + 38.0 / 400, y: 0.5)
        #expect(center > 0.95)
        #expect(half > 0.35 && half < 0.65)
        #expect(edge < 0.15)
    }

    @Test func aStrokeIsAContinuousLineNotAChainOfDots() {
        let image = brush([stroke([(0.2, 0.5), (0.8, 0.5)], size: 0.1)])
        for x in stride(from: 0.2, through: 0.8, by: 0.05) {
            #expect(sampler.maskValue(image, x: x, y: 0.5) > 0.95, "gap at x = \(x)")
        }
        // Its edge is straight: the width does not pulse between dabs.
        let above = (0..<12).map { sampler.maskValue(image, x: 0.3 + Double($0) * 0.03, y: 0.5 - 15.0 / 300) }
        #expect((above.max() ?? 0) - (above.min() ?? 0) < 0.1)
    }

    @Test func overlappingSoftDabsDoNotHardenTheEdge() {
        // One feathered dab and a long feathered stroke should fade over the same distance.
        let dab = brush([stroke([(0.5, 0.5)], size: 0.2, feather: 1)])
        let line = brush([stroke([(0.2, 0.5), (0.8, 0.5)], size: 0.2, feather: 1)])
        for offset in [10.0, 20.0, 30.0] {
            let single = sampler.maskValue(dab, x: 0.5, y: 0.5 + offset / 300)
            let along = sampler.maskValue(line, x: 0.5, y: 0.5 + offset / 300)
            #expect(abs(single - along) < 0.08, "at \(offset) px: \(single) vs \(along)")
        }
    }

    @Test func erasingRemovesPaintAndPaintingAgainRestoresIt() {
        let painted = brush([stroke([(0.5, 0.5)], size: 0.3)])
        let erased = brush([stroke([(0.5, 0.5)], size: 0.3), stroke([(0.5, 0.5)], size: 0.1, erase: true)])
        let repainted = brush([
            stroke([(0.5, 0.5)], size: 0.3), stroke([(0.5, 0.5)], size: 0.1, erase: true), stroke([(0.5, 0.5)], size: 0.05)
        ])

        #expect(sampler.maskValue(painted, x: 0.5, y: 0.5) > 0.98)
        #expect(sampler.maskValue(erased, x: 0.5, y: 0.5) < 0.02, "erased in the middle")
        #expect(sampler.maskValue(erased, x: 0.5 + 40.0 / 400, y: 0.5) > 0.95, "still painted outside the eraser")
        #expect(sampler.maskValue(repainted, x: 0.5, y: 0.5) > 0.98)
    }

    @Test func aBrushMaskIsTheSameCoverageAtAnyResolution() {
        let strokes = [stroke([(0.3, 0.4), (0.7, 0.6)], size: 0.12, feather: 0.5)]
        let small = MaskRenderer.image(for: LocalMask(shape: .brush(strokes: strokes)), extent: CGRect(x: 0, y: 0, width: 400, height: 300))
        let large = MaskRenderer.image(for: LocalMask(shape: .brush(strokes: strokes)), extent: CGRect(x: 0, y: 0, width: 1600, height: 1200))

        for (x, y) in [(0.3, 0.4), (0.5, 0.5), (0.7, 0.6), (0.5, 0.42), (0.1, 0.1), (0.9, 0.9)] {
            #expect(abs(sampler.maskValue(small, x: x, y: y) - sampler.maskValue(large, x: x, y: y)) < 0.08, "at (\(x), \(y))")
        }
    }

    @Test func aHugePhotoRastersTheBrushSmallerAndStillFillsTheFrame() {
        let mask = LocalMask(shape: .brush(strokes: [stroke([(0.5, 0.5)], size: 0.1)]))
        let image = MaskRenderer.image(for: mask, extent: CGRect(x: 0, y: 0, width: 6000, height: 4000))

        #expect(image.extent == CGRect(x: 0, y: 0, width: 6000, height: 4000))
        #expect(sampler.maskValue(image, x: 0.5, y: 0.5) > 0.98)
        #expect(sampler.maskValue(image, x: 0.5 + 250.0 / 6000, y: 0.5) > 0.9, "250 px is inside the 300 px radius")
        #expect(sampler.maskValue(image, x: 0.5 + 400.0 / 6000, y: 0.5) < 0.1)
    }

    private func pixels(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height)
        data.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return data
    }

    @Test func continuingFromAPreviousRasterGivesTheSameImageAsPaintingEverythingAgain() throws {
        let width = 480, height = 320
        let base = (0 ..< 5).map { k in
            stroke([(0.1 + Double(k) * 0.15, 0.2), (0.2 + Double(k) * 0.15, 0.8)], size: 0.08, feather: 0.4)
        } + [stroke([(0.5, 0.5)], size: 0.12, erase: true)]

        // Paint a last stroke one point at a time, as the brush does, using the cache each step.
        var growing = BrushStroke(points: [NormalizedPoint(x: 0.2, y: 0.5)], size: 0.1, feather: 0.6)
        var incremental: CGImage?
        for step in 0 ..< 12 {
            growing.points.append(NormalizedPoint(x: 0.2 + Double(step) * 0.05, y: 0.5 + sin(Double(step)) * 0.1))
            incremental = BrushRasterizer.raster(base + [growing], width: width, height: height)
        }
        // A brand new stroke list forces a from-scratch raster of the same content.
        let fresh = try #require(BrushRasterizer.rasterize(base + [growing], width: width, height: height))

        let a = pixels(try #require(incremental)), b = pixels(fresh)
        #expect(a == b, "\(zip(a, b).filter { $0 != $1 }.count) pixels differ")
    }

    @Test func paintingAnotherStrokeOrChangingAnEarlierOneStillRendersCorrectly() throws {
        let width = 300, height = 200
        let first = stroke([(0.2, 0.5), (0.4, 0.5)], size: 0.1)
        let second = stroke([(0.6, 0.5), (0.8, 0.5)], size: 0.1)
        _ = BrushRasterizer.raster([first], width: width, height: height)
        let both = try #require(BrushRasterizer.raster([first, second], width: width, height: height))
        // Change the first stroke: the cached raster must not be reused.
        let moved = stroke([(0.2, 0.2), (0.4, 0.2)], size: 0.1)
        let changed = try #require(BrushRasterizer.raster([moved, second], width: width, height: height))

        #expect(pixels(both) == pixels(try #require(BrushRasterizer.rasterize([first, second], width: width, height: height))))
        #expect(pixels(changed) == pixels(try #require(BrushRasterizer.rasterize([moved, second], width: width, height: height))))
        #expect(pixels(both) != pixels(changed))
    }

    @Test func addingAPointContinuesFromThePreviousCachedRaster() throws {
        let strokes = (0 ..< 60).map { index in
            stroke([(0.1 + Double(index) * 0.01, 0.3), (0.2 + Double(index) * 0.01, 0.7), (0.3 + Double(index) * 0.01, 0.4)], size: 0.06, feather: 0.6)
        }
        let width = 2560, height = 1707
        var growing = BrushStroke(points: [NormalizedPoint(x: 0.3, y: 0.5)], size: 0.08, feather: 0.5)
        let cache = BrushMaskCache()
        let previous = try #require(BrushRasterizer.raster(strokes + [growing], width: width, height: height, cache: cache))
        growing.points.append(NormalizedPoint(x: 0.4, y: 0.5))
        let base = try #require(cache.continuation(for: strokes + [growing], width: width, height: height))
        #expect(base.image === previous)
        #expect(base.strokeIndex == strokes.count)
        #expect(base.pointCount == 1)
        let continued = try #require(BrushRasterizer.raster(strokes + [growing], width: width, height: height, cache: cache))
        let fresh = try #require(BrushRasterizer.rasterize(strokes + [growing], width: width, height: height))
        #expect(pixels(continued) == pixels(fresh))
    }

    @Test func manyStrokesReuseTheExactCachedRaster() throws {
        let strokes = (0 ..< 40).map { index in
            stroke([(0.1 + Double(index) * 0.02, 0.3), (0.2 + Double(index) * 0.02, 0.7)], size: 0.05, feather: 0.6)
        }
        let cache = BrushMaskCache()
        let first = try #require(BrushRasterizer.raster(strokes, width: 2560, height: 1707, cache: cache))
        let cached = try #require(BrushRasterizer.raster(strokes, width: 2560, height: 1707, cache: cache))
        #expect(cached === first, "Unchanged strokes must reuse the existing bitmap")
    }
}

struct LocalAdjustmentRenderingTests {
    private let sampler = Sampler()
    private let size = CGRect(x: 0, y: 0, width: 400, height: 300)

    private func gray(_ level: Double) -> CIImage {
        CIImage(color: CIColor(red: level, green: level, blue: level, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!)
            .cropped(to: size)
    }

    private func exposureMask(_ ev: Double, shape: MaskShape? = nil, invert: Bool = false, amount: Double = 1, enabled: Bool = true) -> PhotoAdjustments {
        var adjustments = PhotoAdjustments()
        var mask = LocalMask(
            shape: shape ?? .linear(start: NormalizedPoint(x: 0.5, y: 0.2), end: NormalizedPoint(x: 0.5, y: 0.6)),
            invert: invert, amount: amount, isEnabled: enabled
        )
        mask.adjustments.exposure = ev
        adjustments.masks = [mask]
        return adjustments
    }

    private func render(_ adjustments: PhotoAdjustments, source: CIImage? = nil) -> CIImage {
        MediaColorRenderer.render(source ?? gray(0.4), adjustments: adjustments, includesGeometry: true)
    }

    @Test func aMaskedAdjustmentOnlyChangesTheMaskedPart() {
        let base = sampler.color(render(PhotoAdjustments()), x: 0.5, y: 0.5).r
        let output = render(exposureMask(1))

        let top = sampler.color(output, x: 0.5, y: 0.05).r
        let bottom = sampler.color(output, x: 0.5, y: 0.9).r
        #expect(top > base + 30, "+1 EV where the mask is full")
        #expect(abs(bottom - base) <= 2, "untouched where the mask is empty")
        // In between it is partway.
        let middle = sampler.color(output, x: 0.5, y: 0.4).r
        #expect(middle > bottom && middle < top)
    }

    @Test func invertingMovesTheEffectToTheOtherSide() {
        let base = sampler.color(render(PhotoAdjustments()), x: 0.5, y: 0.5).r
        let output = render(exposureMask(1, invert: true))
        #expect(abs(sampler.color(output, x: 0.5, y: 0.05).r - base) <= 2)
        #expect(sampler.color(output, x: 0.5, y: 0.9).r > base + 30)
    }

    @Test func amountScalesTheEffect() {
        let base = sampler.color(render(PhotoAdjustments()), x: 0.5, y: 0.5).r
        let full = sampler.color(render(exposureMask(1)), x: 0.5, y: 0.05).r - base
        let half = sampler.color(render(exposureMask(1, amount: 0.5)), x: 0.5, y: 0.05).r - base
        #expect(half > full / 2 - 8 && half < full / 2 + 8)
    }

    @Test func aDisabledOrEmptyMaskChangesNothing() {
        let plain = sampler.color(render(PhotoAdjustments()), x: 0.5, y: 0.05)
        let disabled = sampler.color(render(exposureMask(1, enabled: false)), x: 0.5, y: 0.05)
        let zero = sampler.color(render(exposureMask(0)), x: 0.5, y: 0.05)
        #expect(disabled == plain && zero == plain)
    }

    @Test func maskedAdjustmentsStackInOrder() {
        var adjustments = exposureMask(1)
        var second = LocalMask(shape: .linear(start: NormalizedPoint(x: 0.5, y: 0.2), end: NormalizedPoint(x: 0.5, y: 0.6)))
        second.adjustments.exposure = 1
        adjustments.masks.append(second)

        let one = sampler.color(render(exposureMask(1)), x: 0.5, y: 0.05).r
        let two = sampler.color(render(adjustments), x: 0.5, y: 0.05).r
        #expect(two > one + 20)
    }

    @Test func aMaskCanDesaturateAndWarmJustItsArea() {
        var adjustments = PhotoAdjustments()
        var mask = LocalMask(shape: .radial(
            center: NormalizedPoint(x: 0.5, y: 0.5), radiusX: 0.2, radiusY: 0.2, rotation: 0, feather: 0.2
        ))
        mask.adjustments.saturation = -1
        adjustments.masks = [mask]

        let color = CIImage(color: CIColor(red: 0.9, green: 0.3, blue: 0.2, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!)
            .cropped(to: size)
        let output = render(adjustments, source: color)

        let inside = sampler.color(output, x: 0.5, y: 0.5)
        let outside = sampler.color(output, x: 0.05, y: 0.05)
        #expect(abs(inside.r - inside.g) < 12 && abs(inside.g - inside.b) < 12, "gray inside")
        #expect(outside.r > 200 && outside.g < 100, "still red outside")
    }

    // MARK: Geometry

    /// A photo that is red along its top edge and blue everywhere else, so where the top went is visible.
    private func topBandImage() -> CIImage {
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!).cropped(to: size)
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!)
            .cropped(to: CGRect(x: 0, y: 270, width: 400, height: 30))
        return red.composited(over: blue)
    }

    @Test func maskedAreasFollowThePhotoWhenItIsRotated() {
        // The mask darkens the top of the original photo, which carries the red band.
        var masked = exposureMask(-2, shape: .linear(start: NormalizedPoint(x: 0.5, y: 0.0), end: NormalizedPoint(x: 0.5, y: 0.3)))
        masked.rotationQuarterTurns = 1
        var plain = PhotoAdjustments()
        plain.rotationQuarterTurns = 1

        let source = topBandImage()
        let without = render(plain, source: source)
        let with = render(masked, source: source)

        // Find which side of the rotated photo holds the red band.
        let left = sampler.color(without, x: 0.02, y: 0.5), right = sampler.color(without, x: 0.98, y: 0.5)
        let bandX = left.r > right.r ? 0.02 : 0.98
        let otherX = 1 - bandX

        let bandBefore = sampler.color(without, x: bandX, y: 0.5).r
        let bandAfter = sampler.color(with, x: bandX, y: 0.5).r
        #expect(bandAfter < bandBefore - 100, "the darkening is over the band's new position")
        #expect(abs(sampler.color(with, x: otherX, y: 0.5).b - sampler.color(without, x: otherX, y: 0.5).b) <= 2)
    }

    @Test func maskedAreasStayOnTheContentWhenCropped() {
        // Crop away the top 40% of the photo (the mask darkens the top 30%): nothing left to darken.
        var cropped = exposureMask(-2, shape: .linear(start: NormalizedPoint(x: 0.5, y: 0.0), end: NormalizedPoint(x: 0.5, y: 0.3)))
        cropped.cropRect = CropRect(x: 0, y: 0, width: 1, height: 0.6)   // bottom 60% (origin bottom-left)
        var plain = PhotoAdjustments()
        plain.cropRect = CropRect(x: 0, y: 0, width: 1, height: 0.6)

        let source = gray(0.5)
        let with = render(cropped, source: source)
        let without = render(plain, source: source)

        #expect(abs(with.extent.height - 180) <= 1)
        for y in [0.05, 0.5, 0.95] {
            #expect(abs(sampler.color(with, x: 0.5, y: y).r - sampler.color(without, x: 0.5, y: y).r) <= 2)
        }

        // Cropping away the bottom instead keeps the darkened part at the top of the result.
        var keepTop = cropped
        keepTop.cropRect = CropRect(x: 0, y: 0.4, width: 1, height: 0.6)
        var keepTopPlain = PhotoAdjustments()
        keepTopPlain.cropRect = keepTop.cropRect
        let darkTop = render(keepTop, source: source), plainTop = render(keepTopPlain, source: source)
        #expect(sampler.color(darkTop, x: 0.5, y: 0.02).r < sampler.color(plainTop, x: 0.5, y: 0.02).r - 40)
    }

    @Test func videoClipsIgnoreMasks() {
        let adjustments = exposureMask(2)
        let with = MediaColorRenderer.render(gray(0.4), adjustments: adjustments, includesGeometry: false)
        let without = MediaColorRenderer.render(gray(0.4), adjustments: PhotoAdjustments(), includesGeometry: false)
        #expect(sampler.color(with, x: 0.5, y: 0.05) == sampler.color(without, x: 0.5, y: 0.05))
    }
}
