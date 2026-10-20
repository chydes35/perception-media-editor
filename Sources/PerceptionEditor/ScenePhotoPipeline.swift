import CoreImage
import CoreImage.CIFilterBuiltins

/// Process version 2: a scene-referred photo pipeline.
///
/// Order, and why:
/// 1. Retouch and orient, as in version 1.
/// 2. White balance in linear light, before any tone.
/// 3. Convert to linear Rec. 2020, so channel-wise math has room for saturated colors.
/// 4. Exposure, tone equalizer (shadows/highlights from a smoothed log-luminance mask), contrast about
///    middle grey. All scene-linear, so nothing clips.
/// 5. Local adjustments, still scene-linear, so a mask can never push past display white.
/// 6. One display transform (sigmoid + gamut compression) turns the scene into display-referred sRGB.
/// 7. Display-referred color and looks: OkLCh saturation/vibrance, tone curves, HSL, grade, LUT.
/// 8. Sharpen, crop, then vignette and grain on the finished frame, so they sit on the final picture.
extension MediaColorRenderer {
    private static let sceneDisplayEncoding = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Linear sRGB primaries to linear Rec. 2020, the rows of the 3×3 matrix. Plain numbers, not
    /// `CIVector`s: a static of non-`Sendable` type fails to compile under Swift 6.1's concurrency checks.
    private static let srgbToRec2020Rows: [[CGFloat]] = [
        [0.627404, 0.329283, 0.043313],
        [0.069097, 0.919540, 0.011362],
        [0.016391, 0.088013, 0.895595],
    ]

    /// `includesGeometry: false` skips retouching, rotation, local masks, crop and grain, as it does in
    /// process 1; analysis (Auto) judges the global look only.
    static func renderScene(
        _ source: CIImage,
        adjustments: PhotoAdjustments,
        isRAW: Bool,
        includesGeometry: Bool = true
    ) -> CIImage {
        guard ScenePhotoKernels.isAvailable else {
            // A Mac that cannot compile the kernels still shows the photo, as version 1.
            return render(source, adjustments: legacy(adjustments), includesGeometry: includesGeometry, highlightRolloff: isRAW)
        }
        let sourceExtent = source.extent
        let repaired = includesGeometry ? RetouchRenderer.apply(source, strokes: adjustments.retouches) : source
        var image = includesGeometry ? orient(repaired, adjustments) : repaired

        if adjustments.temperature != 0 || adjustments.tint != 0 {
            image = whiteBalanced(image, temperature: adjustments.temperature, tint: adjustments.tint)
        }
        image = toRec2020(image)

        image = sceneTone(
            image, exposure: adjustments.exposure + (isRAW ? SceneDisplayCurve.rawExposureOffset : 0),
            contrast: adjustments.contrast,
            shadows: adjustments.shadows, highlights: adjustments.highlights,
            whites: adjustments.whites, blacks: adjustments.blacks)

        for mask in adjustments.masks where includesGeometry && mask.isActive {
            let adjusted = sceneLocalAdjust(image, mask.adjustments)
            let maskImage = orient(MaskRenderer.image(for: mask, extent: sourceExtent), adjustments)
            let blend = CIFilter.blendWithMask()
            blend.inputImage = adjusted
            blend.backgroundImage = image
            blend.maskImage = maskImage
            image = blend.outputImage ?? image
        }

        let curve = isRAW ? SceneDisplayCurve.raw : SceneDisplayCurve.displayReferred
        image = ScenePhotoKernels.display(image, curve: curve) ?? image

        if adjustments.saturation != 0 || adjustments.vibrance != 0,
           let colored = ScenePhotoKernels.saturation(
               image, saturation: max(0, 1 + adjustments.saturation), vibrance: adjustments.vibrance) {
            image = colored
        }

        if let curveData = ColorGrading.curveData(adjustments.curves) {
            let curves = CIFilter.colorCurves()
            curves.inputImage = image
            curves.curvesData = curveData
            curves.curvesDomain = CIVector(x: 0, y: 1)
            curves.colorSpace = sceneDisplayEncoding
            image = curves.outputImage ?? image
        }
        if let hsl = adjustments.hsl, !hsl.isNeutral { image = applyHSL(hsl, to: image) }
        if let grading = adjustments.grading, !grading.isNeutral { image = applyColorGrade(grading, to: image) }
        if let lut = adjustments.lut { image = applyCreativeLUT(lut, to: image) }

        if adjustments.sharpness > 0 {
            let longEdge = max(image.extent.width, image.extent.height)
            let sharpen = CIFilter.sharpenLuminance()
            sharpen.inputImage = image
            sharpen.sharpness = Float(adjustments.sharpness * 1.5)
            // The radius follows the picture's size, so a preview and the full-size export match.
            sharpen.radius = Float(max(0.5, 1.69 * longEdge / 2560))
            image = sharpen.outputImage ?? image
        }

        if includesGeometry { image = crop(image, to: adjustments.cropAspect, rect: adjustments.cropRect) }

        if adjustments.vignette > 0 {
            let vignette = CIFilter.vignette()
            vignette.inputImage = image
            vignette.intensity = Float(adjustments.vignette * 2)
            vignette.radius = Float(min(image.extent.width, image.extent.height) * 0.55)
            image = vignette.outputImage ?? image
        }
        if includesGeometry, let grain = adjustments.grain, !grain.isNeutral { image = applyGrain(grain, to: image) }
        return image
    }

    /// The render Auto judges its candidates by: the photo's own process, global look only.
    static func renderForAnalysis(_ source: CIImage, adjustments: PhotoAdjustments, isRAW: Bool) -> CIImage {
        if adjustments.processVersion >= 2 {
            return renderScene(source, adjustments: adjustments, isRAW: isRAW, includesGeometry: false)
        }
        return render(source, adjustments: adjustments, includesGeometry: false, highlightRolloff: isRAW)
    }

    /// An image as the photo's process shows it with nothing adjusted: the baseline Auto measures from.
    static func neutralDisplay(_ source: CIImage, process: Int, isRAW: Bool) -> CIImage {
        var neutral = PhotoAdjustments.neutral
        neutral.processVersion = process
        return renderForAnalysis(source, adjustments: neutral, isRAW: isRAW)
    }

    // MARK: - Stages

    private static func legacy(_ adjustments: PhotoAdjustments) -> PhotoAdjustments {
        var copy = adjustments
        copy.processVersion = 1
        return copy
    }

    static func whiteBalanced(_ image: CIImage, temperature: Double, tint: Double) -> CIImage {
        let filter = CIFilter.temperatureAndTint()
        filter.inputImage = image
        filter.neutral = CIVector(x: 6500, y: 0)
        filter.targetNeutral = CIVector(x: 6500 + temperature * 2200, y: tint * 120)
        return filter.outputImage ?? image
    }

    private static func toRec2020(_ image: CIImage) -> CIImage {
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = image
        let rows = srgbToRec2020Rows
        matrix.rVector = CIVector(x: rows[0][0], y: rows[0][1], z: rows[0][2], w: 0)
        matrix.gVector = CIVector(x: rows[1][0], y: rows[1][1], z: rows[1][2], w: 0)
        matrix.bVector = CIVector(x: rows[2][0], y: rows[2][1], z: rows[2][2], w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        matrix.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        return matrix.outputImage ?? image
    }

    /// How strongly each slider moves each equalizer band, in EV per full slider travel. Bands run
    /// from −8 to 0 EV below white; the shadows slider mostly moves the dark-to-mid bands, the
    /// highlights slider the bright ones.
    static func toneBands(shadows: Double, highlights: Double, blacks: Double = 0, whites: Double = 0) -> [Double] {
        let shadowProfile: [Double] = [0, 0.3, 0.7, 1, 1, 0.8, 0.3, 0, 0]
        let highlightProfile: [Double] = [0, 0, 0, 0, 0, 0.2, 0.6, 1, 1]
        let blackProfile: [Double] = [1, 1, 0.5, 0, 0, 0, 0, 0, 0]
        let whiteProfile: [Double] = [0, 0, 0, 0, 0, 0, 0, 0.4, 1]
        return (0 ..< ScenePhotoKernels.bandCenters.count).map { index in
            1.5 * (shadows * shadowProfile[index] + highlights * highlightProfile[index]
                + blacks * blackProfile[index] + whites * whiteProfile[index])
        }
    }

    /// Smoothed log-luminance, the tone equalizer's mask. The radius is a share of the long edge so a
    /// 2560 px preview and a full-size export smooth the same part of the picture.
    private static func toneMask(for image: CIImage) -> CIImage? {
        guard let logLuma = ScenePhotoKernels.logLuma(image) else { return nil }
        let extent = image.extent
        let sigma = max(2, max(extent.width, extent.height) * 0.008)
        return logLuma.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
    }

    private static func sceneTone(
        _ image: CIImage, exposure: Double, contrast: Double, shadows: Double, highlights: Double,
        whites: Double = 0, blacks: Double = 0
    ) -> CIImage {
        let bands = toneBands(shadows: shadows, highlights: highlights, blacks: blacks, whites: whites)
        let gain = pow(2, exposure)
        let contrastExponent = 1 + 0.5 * contrast
        guard exposure != 0 || contrast != 0 || bands.contains(where: { $0 != 0 }) else { return image }
        // The mask is only needed when a band moves; a constant stands in otherwise.
        let mask = bands.contains(where: { $0 != 0 }) ? (toneMask(for: image) ?? image) : image
        return ScenePhotoKernels.tone(
            image, mask: mask, gain: gain, bands: bands, contrast: contrastExponent,
            pivot: SceneDisplayCurve.middleGrey) ?? image
    }

    /// The masked adjustments on scene-linear color, with the same slider scales as the global ones.
    private static func sceneLocalAdjust(_ source: CIImage, _ adjustments: MaskAdjustments) -> CIImage {
        var image = sceneTone(
            source, exposure: adjustments.exposure, contrast: adjustments.contrast,
            shadows: adjustments.shadows, highlights: adjustments.highlights)
        if adjustments.temperature != 0 || adjustments.tint != 0 {
            image = whiteBalanced(image, temperature: adjustments.temperature, tint: adjustments.tint)
        }
        if adjustments.saturation != 0 {
            let controls = CIFilter.colorControls()
            controls.inputImage = image
            controls.saturation = Float(max(0, 1 + adjustments.saturation))
            image = controls.outputImage ?? image
        }
        if adjustments.sharpness > 0 {
            let sharpen = CIFilter.sharpenLuminance()
            sharpen.inputImage = image
            sharpen.sharpness = Float(adjustments.sharpness * 1.5)
            image = sharpen.outputImage ?? image
        }
        return image
    }
}
