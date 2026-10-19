import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
@testable import PerceptionEditor

/// 8-bit sRGB statistics: median luma and the share of pixels with any channel at 254 or above.
private func clipStatistics(_ image: CGImage) -> (median: Double, clipped: Double) {
    let width = 512, height = max(1, Int(Double(image.height) / Double(image.width) * 512))
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .none
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var lumas: [Double] = []
    var clipped = 0
    for index in stride(from: 0, to: pixels.count, by: 4) {
        let r = pixels[index], g = pixels[index + 1], b = pixels[index + 2]
        let weighted: Double = 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
        lumas.append(weighted / 255)
        if max(r, g, b) >= 254 { clipped += 1 }
    }
    lumas.sort()
    return (lumas[lumas.count / 2], Double(clipped) / Double(lumas.count))
}

private func linearPixel(_ image: CIImage) -> (Float, Float, Float) {
    var pixel = [Float](repeating: 0, count: 4)
    CIContext().render(image, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
    return (pixel[0], pixel[1], pixel[2])
}

private func solid(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CIImage {
    CIImage(color: CIColor(red: r, green: g, blue: b, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)!)
        .cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
}

struct HighlightRolloffCurveTests {
    @Test func belowTheKneeNothingChanges() {
        for value in stride(from: 0.0, through: HighlightRolloff.knee, by: 0.05) {
            #expect(HighlightRolloff.map(value, white: HighlightRolloff.baseWhite) == value)
        }
    }

    @Test func theCurveIsSmoothMonotonicAndReachesWhiteExactlyAtTheWhitePoint() {
        let white = HighlightRolloff.baseWhite
        let knee = HighlightRolloff.knee
        // Slope 1 just above the knee, so there is no visible kink.
        let slope = (HighlightRolloff.map(knee + 0.001, white: white) - HighlightRolloff.map(knee, white: white)) / 0.001
        #expect(abs(slope - 1) < 0.01)
        var previous = 0.0
        for value in stride(from: 0.0, through: white, by: 0.01) {
            let mapped = HighlightRolloff.map(value, white: white)
            #expect(mapped >= previous)
            #expect(mapped <= 1)
            previous = mapped
        }
        #expect(abs(HighlightRolloff.map(white, white: white) - 1) < 1e-9)
    }

    @Test func lowerHighlightsMoveTheWhitePointUp() {
        #expect(HighlightRolloff.whitePoint(highlights: 0) == HighlightRolloff.baseWhite)
        #expect(HighlightRolloff.whitePoint(highlights: -1) > HighlightRolloff.whitePoint(highlights: -0.5))
        #expect(HighlightRolloff.whitePoint(highlights: -0.5) > HighlightRolloff.baseWhite)
        #expect(HighlightRolloff.whitePoint(highlights: 0.5) < HighlightRolloff.baseWhite)
        #expect(HighlightRolloff.whitePoint(highlights: 1) > HighlightRolloff.knee)
        #expect(HighlightRolloff.kneePoint(highlights: 0) == HighlightRolloff.knee)
        #expect(HighlightRolloff.kneePoint(highlights: 0.7) == HighlightRolloff.knee)
        #expect(HighlightRolloff.kneePoint(highlights: -1) == HighlightRolloff.knee / 2)
    }

    /// Core Image's highlight adjustment amplifies values above white, so RAW renders must not
    /// use it for the Highlights slider.
    @Test func rawHighlightsNeverPushPixelsBackAboveWhite() {
        var adjustments = PhotoAdjustments.neutral
        adjustments.highlights = -1
        let bright = solid(5.0, 4.0, 3.0)
        let (r, g, b) = linearPixel(MediaColorRenderer.render(bright, adjustments: adjustments, includesGeometry: false,
                                                              highlightRolloff: true))
        #expect(max(r, g, b) <= 1.0001)
        // −1 shows more detail than 0: the same pixel ends up darker.
        let (r0, _, _) = linearPixel(MediaColorRenderer.render(bright, adjustments: .neutral, includesGeometry: false,
                                                               highlightRolloff: true))
        #expect(r < r0)
    }

    @Test func renderingKeepsOverWhiteValuesInRangeAndKeepsHue() {
        // A saturated warm color below the knee in luminance and within range is unchanged.
        let (r1, g1, b1) = linearPixel(MediaColorRenderer.render(solid(0.8, 0.4, 0.16), adjustments: .neutral,
                                                                 includesGeometry: false, highlightRolloff: true))
        #expect(abs(r1 - 0.8) < 0.001 && abs(g1 - 0.4) < 0.001 && abs(b1 - 0.16) < 0.001)
        // Bright sky blue: its luminance is above white, so it must come out brighter than a
        // dimmer blue, never darker (the dark-band failure), and pale toward white.
        let skyBright = linearPixel(MediaColorRenderer.render(solid(0.74, 1.24, 2.05), adjustments: .neutral,
                                                              includesGeometry: false, highlightRolloff: true))
        let skyDim = linearPixel(MediaColorRenderer.render(solid(0.45, 0.63, 0.82), adjustments: .neutral,
                                                           includesGeometry: false, highlightRolloff: true))
        func luma(_ p: (Float, Float, Float)) -> Float {
            let weighted: Float = 0.2126 * p.0 + 0.7152 * p.1 + 0.0722 * p.2
            return weighted
        }
        #expect(luma(skyBright) > luma(skyDim))
        #expect(max(skyBright.0, skyBright.1, skyBright.2) <= 1.0001)
        // A bright warm highlight, well above white in linear light, stays in range, keeps its
        // channel order, and pales toward white.
        let warm = solid(3.0, 1.5, 0.6)
        let (r, g, b) = linearPixel(MediaColorRenderer.render(warm, adjustments: .neutral, includesGeometry: false,
                                                              highlightRolloff: true))
        #expect(max(r, g, b) <= 1.0001)
        #expect(r >= g && g >= b)
        #expect(Double(b / r) > 0.2)
        // Without the shoulder the same pixel is left above white, as before.
        let (r0, _, _) = linearPixel(MediaColorRenderer.render(warm, adjustments: .neutral, includesGeometry: false))
        #expect(r0 > 2.9)
        // Midtones are untouched.
        let mid = solid(0.18, 0.18, 0.18)
        let (m, _, _) = linearPixel(MediaColorRenderer.render(mid, adjustments: .neutral, includesGeometry: false,
                                                              highlightRolloff: true))
        #expect(abs(m - 0.18) < 0.0005)
    }

    @Test func onlyRAWDecodesGetTheShoulder() throws {
        let folder = try TempDirectory()
        let jpeg = try writeTestJPEG(to: folder.url.appendingPathComponent("a.jpg"))
        #expect(PhotoSourceLoader.loadThumbnailSource(jpeg, maxDimension: 200)?.hasHeadroom == false)
        #expect(!PhotoSourceLoader.hasHeadroom(jpeg))
        if let raw = RawSample.url {
            #expect(PhotoSourceLoader.hasHeadroom(raw))
            // Thumbnails from the camera's embedded JPEG have no headroom; a RAW decode does.
            #expect(PhotoSourceLoader.loadThumbnailSource(raw, maxDimension: 420)?.hasHeadroom == false)
            var settings = RawSettings()
            settings.temperature = 5000
            #expect(PhotoSourceLoader.loadThumbnailSource(raw, maxDimension: 420, raw: settings)?.hasHeadroom == true)
        }
    }
}

/// The photographer's report frame. Set PME_ROLLOFF_RAW to a copy of P1107263.RW2 (or any sunny RW2).
struct HighlightRolloffRealRawTests {
    static let path = ProcessInfo.processInfo.environment["PME_ROLLOFF_RAW"]

    @Test(.enabled(if: path != nil))
    func untouchedRAWClipsNoMoreThanTheCameraJPEGAndKeepsItsMidtones() async throws {
        let url = URL(fileURLWithPath: try #require(Self.path))
        let camera = try #require(PhotoSourceLoader.loadCullPreview(url))
        let renderer = PhotoRenderer()
        let preview = try #require(await renderer.preview(url: url, adjustments: .neutral)).edited.cgImage
        let source = try #require(PhotoSourceLoader.load(url, maxDimension: PhotoRenderer.previewDimension))
        let legacy = try #require(CIContext().createCGImage(
            MediaColorRenderer.render(source, adjustments: .neutral, includesGeometry: true),
            from: source.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
        let cameraStats = clipStatistics(camera), now = clipStatistics(preview), before = clipStatistics(legacy)
        print(String(format: "ROLLOFF camera clipped %.1f%% median %.3f | before %.1f%% %.3f | now %.1f%% %.3f",
                     cameraStats.clipped * 100, cameraStats.median, before.clipped * 100, before.median,
                     now.clipped * 100, now.median))
        #expect(now.clipped <= cameraStats.clipped)
        #expect(abs(now.median - before.median) <= 0.02)
    }

    @Test(.enabled(if: path != nil))
    func highlightsMinusOneRecoversTheBlownAreas() async throws {
        let url = URL(fileURLWithPath: try #require(Self.path))
        let renderer = PhotoRenderer()
        let neutral = clipStatistics(try #require(await renderer.preview(url: url, adjustments: .neutral)).edited.cgImage)
        var recovered = PhotoAdjustments.neutral
        recovered.highlights = -1
        let result = clipStatistics(try #require(await renderer.preview(url: url, adjustments: recovered)).edited.cgImage)
        print(String(format: "ROLLOFF highlights -1: clipped %.1f%% median %.3f (neutral %.3f)",
                     result.clipped * 100, result.median, neutral.median))
        #expect(result.clipped < 0.02)
        #expect(neutral.median - result.median <= 0.03)
    }
}

/// Share of pixels in a region (fractions of the frame from the top-left) where the camera JPEG is
/// near white (luma ≥ 0.93) and `image` is at least 0.12 darker.
private func darkerThanCamera(_ image: CGImage, camera: CGImage, x: ClosedRange<Double>, y: ClosedRange<Double>) -> Double {
    func lumas(_ source: CGImage, _ width: Int, _ height: Int) -> [Double] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        var result: [Double] = []
        result.reserveCapacity(width * height)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[index])
            let g = Double(pixels[index + 1])
            let b = Double(pixels[index + 2])
            let weighted: Double = 0.2126 * r + 0.7152 * g + 0.0722 * b
            result.append(weighted / 255)
        }
        return result
    }
    let width = 512, height = max(1, Int(Double(image.height) / Double(image.width) * 512))
    let ours = lumas(image, width, height), theirs = lumas(camera, width, height)
    var darker = 0.0, count = 0.0
    for row in Int(y.lowerBound * Double(height)) ..< Int(y.upperBound * Double(height)) {
        for column in Int(x.lowerBound * Double(width)) ..< Int(x.upperBound * Double(width)) {
            let index = row * width + column
            count += 1
            if theirs[index] >= 0.93 && ours[index] <= theirs[index] - 0.12 { darker += 1 }
        }
    }
    return darker / max(1, count)
}

/// Mean saturation inside a region given as fractions of the frame, measured from the top-left.
private func regionSaturation(_ image: CGImage, x: ClosedRange<Double>, y: ClosedRange<Double>) -> Double {
    let width = 512, height = max(1, Int(Double(image.height) / Double(image.width) * 512))
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var total = 0.0, count = 0.0
    for row in Int(y.lowerBound * Double(height)) ..< Int(y.upperBound * Double(height)) {
        for column in Int(x.lowerBound * Double(width)) ..< Int(x.upperBound * Double(width)) {
            let index = (row * width + column) * 4
            let r = Double(pixels[index]), g = Double(pixels[index + 1]), b = Double(pixels[index + 2])
            let high = max(r, g, b)
            total += high > 0 ? (high - min(r, g, b)) / high : 0
            count += 1
        }
    }
    return total / max(1, count)
}

/// 8-bit sRGB: mean saturation, and the share of bright pixels that still carry a tint.
private func colorStatistics(_ image: CGImage) -> (meanSaturation: Double, brightTinted: Double) {
    let width = 512, height = max(1, Int(Double(image.height) / Double(image.width) * 512))
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var saturation = 0.0, tinted = 0
    for index in stride(from: 0, to: pixels.count, by: 4) {
        let r = Double(pixels[index]) / 255, g = Double(pixels[index + 1]) / 255, b = Double(pixels[index + 2]) / 255
        let high = max(r, g, b), low = min(r, g, b)
        let s = high > 0 ? (high - low) / high : 0
        saturation += s
        let luminance: Double = 0.2126 * r + 0.7152 * g + 0.0722 * b
        if luminance > 0.85 && s > 0.12 { tinted += 1 }
    }
    let count = Double(pixels.count / 4)
    return (saturation / count, Double(tinted) / count)
}

/// Frames from the 2026-10-18 shoot where the sensor clipped: P1107332 (a blown lake behind the
/// subject) and P1107263 (sunlit yellow flowers). Set PME_ROLLOFF_DIR to a folder holding copies.
struct HighlightRolloffClippedSensorTests {
    static let directory = ProcessInfo.processInfo.environment["PME_ROLLOFF_DIR"]

    @Test(.enabled(if: directory != nil))
    func rebuiltNeutralHighlightsShowNoTintedBand() async throws {
        let url = URL(fileURLWithPath: try #require(Self.directory)).appendingPathComponent("P1107332.RW2")
        let preview = try #require(await PhotoRenderer().preview(url: url, adjustments: .neutral)).edited.cgImage
        // The top of the frame: bright sky over sunlit grass blown to white. The band was bright
        // blue sky rendered darker than both its neighbours. Count pixels the camera shows near
        // white that the editor shows clearly darker.
        let camera = try #require(PhotoSourceLoader.loadCullPreview(url))
        let darkRim = darkerThanCamera(preview, camera: camera, x: 0.30 ... 0.80, y: 0.0 ... 0.12)
        print(String(format: "BAND P1107332 dark rim %.2f%%", darkRim * 100))
        #expect(darkRim < 0.01)
    }

    /// P1107263: sunlit yellow mums. P1107437: mums whose petals clipped at the sensor.
    @Test(.enabled(if: directory != nil), arguments: ["P1107263.RW2", "P1107437.RW2"])
    func sunlitColorsAreNotBleached(_ name: String) async throws {
        let url = URL(fileURLWithPath: try #require(Self.directory)).appendingPathComponent(name)
        let preview = try #require(await PhotoRenderer().preview(url: url, adjustments: .neutral)).edited.cgImage
        // The plain RAW decode, clipped at white as before the shoulder existed.
        let source = try #require(PhotoSourceLoader.makeRawFilter(url, settings: RawSettings(),
                                                                  maxDimension: PhotoRenderer.previewDimension)?.outputImage)
        let legacy = try #require(CIContext().createCGImage(
            MediaColorRenderer.render(source, adjustments: .neutral, includesGeometry: true),
            from: source.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
        let now = colorStatistics(preview), before = colorStatistics(legacy)
        print(String(format: "BLEACH %@ mean saturation before %.3f now %.3f", name, before.meanSaturation, now.meanSaturation))
        #expect(now.meanSaturation >= before.meanSaturation - 0.005)
    }
}
