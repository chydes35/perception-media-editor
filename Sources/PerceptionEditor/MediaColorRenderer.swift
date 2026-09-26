import CoreImage
import CoreImage.CIFilterBuiltins

enum MediaColorRenderer {
    static func render(
        _ source: CIImage,
        adjustments: PhotoAdjustments,
        includesGeometry: Bool
    ) -> CIImage {
        var image = source

        if includesGeometry, adjustments.rotationQuarterTurns != 0 {
            let radians = CGFloat(adjustments.rotationQuarterTurns) * .pi / 2
            image = image.transformed(by: CGAffineTransform(rotationAngle: radians))
            let normalized = image.extent
            image = image.transformed(
                by: CGAffineTransform(translationX: -normalized.origin.x, y: -normalized.origin.y)
            )
        }

        if includesGeometry, let degrees = adjustments.straightenDegrees, abs(degrees) > 0.001 {
            image = image.transformed(by: CGAffineTransform(rotationAngle: CGFloat(degrees) * .pi / 180))
            let normalized = image.extent
            image = image.transformed(
                by: CGAffineTransform(translationX: -normalized.origin.x, y: -normalized.origin.y)
            )
        }

        let exposure = CIFilter.exposureAdjust()
        exposure.inputImage = image
        exposure.ev = Float(adjustments.exposure)
        image = exposure.outputImage ?? image

        let controls = CIFilter.colorControls()
        controls.inputImage = image
        controls.contrast = Float(1 + adjustments.contrast)
        controls.saturation = Float(max(0, 1 + adjustments.saturation))
        image = controls.outputImage ?? image

        let highlightShadow = CIFilter.highlightShadowAdjust()
        highlightShadow.inputImage = image
        highlightShadow.highlightAmount = Float(1 + adjustments.highlights)
        highlightShadow.shadowAmount = Float(adjustments.shadows)
        image = highlightShadow.outputImage ?? image

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

    private static func crop(_ image: CIImage, to aspect: CropAspect, rect: CropRect?) -> CIImage {
        if let rect {
            let extent = image.extent
            let normalized = CGRect(
                x: extent.minX + extent.width * rect.x,
                y: extent.minY + extent.height * rect.y,
                width: extent.width * rect.width,
                height: extent.height * rect.height
            )
            let cropped = image.cropped(to: normalized.integral)
            return cropped.transformed(
                by: CGAffineTransform(translationX: -cropped.extent.origin.x, y: -cropped.extent.origin.y)
            )
        }

        guard let ratio = aspect.ratio else { return image }

        let extent = image.extent
        let currentRatio = extent.width / extent.height
        let cropRect: CGRect

        if currentRatio > ratio {
            let width = extent.height * ratio
            cropRect = CGRect(
                x: extent.midX - width / 2,
                y: extent.minY,
                width: width,
                height: extent.height
            )
        } else {
            let height = extent.width / ratio
            cropRect = CGRect(
                x: extent.minX,
                y: extent.midY - height / 2,
                width: extent.width,
                height: height
            )
        }

        let cropped = image.cropped(to: cropRect.integral)
        return cropped.transformed(
            by: CGAffineTransform(translationX: -cropped.extent.origin.x, y: -cropped.extent.origin.y)
        )
    }
}
