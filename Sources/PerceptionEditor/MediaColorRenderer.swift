import CoreImage
import CoreImage.CIFilterBuiltins

enum MediaColorRenderer {
    private static let encodingSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    static func render(
        _ source: CIImage,
        adjustments: PhotoAdjustments,
        includesGeometry: Bool,
        highlightRolloff: Bool = false
    ) -> CIImage {
        let sourceExtent = source.extent
        let repaired = includesGeometry ? RetouchRenderer.apply(source, strokes: adjustments.retouches) : source
        var image = includesGeometry ? orient(repaired, adjustments) : repaired

        let exposure = CIFilter.exposureAdjust()
        exposure.inputImage = image
        exposure.ev = Float(adjustments.exposure)
        image = exposure.outputImage ?? image

        let controls = CIFilter.colorControls()
        controls.inputImage = image
        controls.contrast = Float(1 + adjustments.contrast)
        controls.saturation = Float(max(0, 1 + adjustments.saturation))
        image = controls.outputImage ?? image

        // On RAW decodes the Highlights slider drives the shoulder below: Core Image's highlight
        // adjustment amplifies values above white (up to 58× on a sunny S5 frame at −1).
        let highlightShadow = CIFilter.highlightShadowAdjust()
        highlightShadow.inputImage = image
        highlightShadow.highlightAmount = Float(highlightRolloff ? 1 : 1 + adjustments.highlights)
        highlightShadow.shadowAmount = Float(adjustments.shadows)
        image = highlightShadow.outputImage ?? image

        // RAW photos carry highlights above white. Bring them into range here, before curves,
        // HSL and LUTs, which expect 0–1. Other photos and video have no such headroom.
        if highlightRolloff {
            image = HighlightRolloff.apply(image, highlights: adjustments.highlights)
        }

        // Curves and HSL work on gamma-encoded color, where equal steps look equal. Both are
        // skipped when untouched so highlights above white keep their headroom.
        if let curveData = ColorGrading.curveData(adjustments.curves) {
            let curves = CIFilter.colorCurves()
            curves.inputImage = image
            curves.curvesData = curveData
            curves.curvesDomain = CIVector(x: 0, y: 1)
            curves.colorSpace = Self.encodingSpace
            image = curves.outputImage ?? image
        }

        if adjustments.temperature != 0 || adjustments.tint != 0 {
            let temperature = CIFilter.temperatureAndTint()
            temperature.inputImage = image
            temperature.neutral = CIVector(x: 6500, y: 0)
            temperature.targetNeutral = CIVector(
                x: 6500 + adjustments.temperature * 2200,
                y: adjustments.tint * 120
            )
            image = temperature.outputImage ?? image
        }

        if adjustments.vibrance != 0 {
            let vibrance = CIFilter.vibrance()
            vibrance.inputImage = image
            vibrance.amount = Float(adjustments.vibrance)
            image = vibrance.outputImage ?? image
        }

        if let hsl = adjustments.hsl, !hsl.isNeutral {
            let cube = CIFilter.colorCubeWithColorSpace()
            cube.inputImage = image
            cube.cubeDimension = Float(ColorGrading.cubeDimension)
            cube.cubeData = ColorGrading.hslCube(hsl)
            cube.colorSpace = Self.encodingSpace
            cube.extrapolate = true
            image = cube.outputImage ?? image
        }

        // Local adjustments come after the global ones, as in Lightroom. Video clips have no masks.
        if includesGeometry {
            image = applyMasks(image, adjustments: adjustments, sourceExtent: sourceExtent)
        }

        if adjustments.sharpness > 0 {
            let sharpen = CIFilter.sharpenLuminance()
            sharpen.inputImage = image
            sharpen.sharpness = Float(adjustments.sharpness * 1.5)
            image = sharpen.outputImage ?? image
        }

        if adjustments.vignette > 0 {
            let vignette = CIFilter.vignette()
            vignette.inputImage = image
            vignette.intensity = Float(adjustments.vignette * 2)
            vignette.radius = Float(min(image.extent.width, image.extent.height) * 0.55)
            image = vignette.outputImage ?? image
        }

        return includesGeometry ? crop(image, to: adjustments.cropAspect, rect: adjustments.cropRect) : image
    }

    // MARK: - Geometry

    /// Quarter-turn rotation and straighten. Masks go through the same steps as the photo so
    /// they stay on the same part of the picture.
    static func orient(_ source: CIImage, _ adjustments: PhotoAdjustments) -> CIImage {
        var image = source

        if adjustments.rotationQuarterTurns != 0 {
            let radians = CGFloat(adjustments.rotationQuarterTurns) * .pi / 2
            image = image.transformed(by: CGAffineTransform(rotationAngle: radians))
            let normalized = image.extent
            image = image.transformed(
                by: CGAffineTransform(translationX: -normalized.origin.x, y: -normalized.origin.y)
            )
        }

        if let degrees = adjustments.straightenDegrees, abs(degrees) > 0.001 {
            image = image.transformed(by: CGAffineTransform(rotationAngle: CGFloat(degrees) * .pi / 180))
            let normalized = image.extent
            image = image.transformed(
                by: CGAffineTransform(translationX: -normalized.origin.x, y: -normalized.origin.y)
            )
        }
        return image
    }

    /// An image that covers the original photo (a mask, for example) carried through the same
    /// rotation, straighten, and crop as the finished photo.
    static func finishedGeometry(_ source: CIImage, _ adjustments: PhotoAdjustments) -> CIImage {
        crop(orient(source, adjustments), to: adjustments.cropAspect, rect: adjustments.cropRect)
    }

    // MARK: - Local adjustments

    private static func applyMasks(
        _ image: CIImage,
        adjustments: PhotoAdjustments,
        sourceExtent: CGRect
    ) -> CIImage {
        var result = image
        for mask in adjustments.masks where mask.isActive {
            let adjusted = localAdjust(result, mask.adjustments)
            let maskImage = orient(MaskRenderer.image(for: mask, extent: sourceExtent), adjustments)

            let blend = CIFilter.blendWithMask()
            blend.inputImage = adjusted
            blend.backgroundImage = result
            blend.maskImage = maskImage
            result = blend.outputImage ?? result
        }
        return result
    }

    /// The masked adjustments, using the same filters and scales as the global sliders.
    private static func localAdjust(_ source: CIImage, _ adjustments: MaskAdjustments) -> CIImage {
        var image = source

        if adjustments.exposure != 0 {
            let exposure = CIFilter.exposureAdjust()
            exposure.inputImage = image
            exposure.ev = Float(adjustments.exposure)
            image = exposure.outputImage ?? image
        }
        if adjustments.contrast != 0 || adjustments.saturation != 0 {
            let controls = CIFilter.colorControls()
            controls.inputImage = image
            controls.contrast = Float(1 + adjustments.contrast)
            controls.saturation = Float(max(0, 1 + adjustments.saturation))
            image = controls.outputImage ?? image
        }
        if adjustments.highlights != 0 || adjustments.shadows != 0 {
            let highlightShadow = CIFilter.highlightShadowAdjust()
            highlightShadow.inputImage = image
            highlightShadow.highlightAmount = Float(1 + adjustments.highlights)
            highlightShadow.shadowAmount = Float(adjustments.shadows)
            image = highlightShadow.outputImage ?? image
        }
        if adjustments.temperature != 0 || adjustments.tint != 0 {
            let temperature = CIFilter.temperatureAndTint()
            temperature.inputImage = image
            temperature.neutral = CIVector(x: 6500, y: 0)
            temperature.targetNeutral = CIVector(
                x: 6500 + adjustments.temperature * 2200,
                y: adjustments.tint * 120
            )
            image = temperature.outputImage ?? image
        }
        if adjustments.sharpness > 0 {
            let sharpen = CIFilter.sharpenLuminance()
            sharpen.inputImage = image
            sharpen.sharpness = Float(adjustments.sharpness * 1.5)
            image = sharpen.outputImage ?? image
        }
        return image
    }

    private static func crop(_ image: CIImage, to aspect: CropAspect, rect: CropRect?) -> CIImage {
        guard let area = ImageGeometry.cropArea(in: image.extent, aspect: aspect, rect: rect) else { return image }
        let cropped = image.cropped(to: area)
        return cropped.transformed(
            by: CGAffineTransform(translationX: -cropped.extent.origin.x, y: -cropped.extent.origin.y)
        )
    }
}
