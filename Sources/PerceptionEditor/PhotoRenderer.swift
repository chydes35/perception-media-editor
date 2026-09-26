import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers

@MainActor
final class PhotoRenderer {
    static let shared = PhotoRenderer()

    private let context = CIContext(options: [
        .cacheIntermediates: true,
        .useSoftwareRenderer: false
    ])

    private init() {}

    func loadImage(from url: URL) -> CIImage? {
        CIImage(contentsOf: url, options: [
            .applyOrientationProperty: true,
            .cacheImmediately: true
        ])
    }

    func render(_ source: CIImage, adjustments: PhotoAdjustments) -> CIImage {
        var image = source

        if adjustments.rotationQuarterTurns != 0 {
            let radians = CGFloat(adjustments.rotationQuarterTurns) * .pi / 2
            image = image.transformed(by: CGAffineTransform(rotationAngle: radians))
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

        return crop(image, to: adjustments.cropAspect)
    }

    func preview(_ source: CIImage, adjustments: PhotoAdjustments, maxDimension: CGFloat = 1800) -> NSImage? {
        let edited = render(source, adjustments: adjustments)
        let extent = edited.extent.integral
        let scale = min(1, maxDimension / max(extent.width, extent.height))
        let scaled = scale < 1
            ? edited.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : edited

        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    func histogram(_ source: CIImage, adjustments: PhotoAdjustments) -> HistogramData {
        let edited = render(source, adjustments: adjustments)
        let extent = edited.extent.integral
        guard extent.width > 0, extent.height > 0 else { return .empty }

        let maximumDimension: CGFloat = 256
        let scale = min(maximumDimension / extent.width, maximumDimension / extent.height, 1)
        let normalized = edited.transformed(
            by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y)
        )
        let scaled = normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let width = max(1, Int(scaled.extent.width.rounded(.down)))
        let height = max(1, Int(scaled.extent.height.rounded(.down)))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

        pixels.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            context.render(
                scaled,
                toBitmap: baseAddress,
                rowBytes: width * 4,
                bounds: CGRect(x: 0, y: 0, width: width, height: height),
                format: .RGBA8,
                colorSpace: colorSpace
            )
        }

        var red = [Double](repeating: 0, count: 256)
        var green = [Double](repeating: 0, count: 256)
        var blue = [Double](repeating: 0, count: 256)

        for index in stride(from: 0, to: pixels.count, by: 4) {
            red[Int(pixels[index])] += 1
            green[Int(pixels[index + 1])] += 1
            blue[Int(pixels[index + 2])] += 1
        }

        return HistogramData(
            red: normalize(red),
            green: normalize(green),
            blue: normalize(blue)
        )
    }

    func export(
        _ source: CIImage,
        adjustments: PhotoAdjustments,
        to url: URL,
        type: UTType,
        quality: CGFloat = 0.92
    ) throws {
        let image = render(source, adjustments: adjustments)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

        if type == .png {
            try context.writePNGRepresentation(
                of: image,
                to: url,
                format: .RGBA8,
                colorSpace: colorSpace
            )
        } else {
            try context.writeJPEGRepresentation(
                of: image,
                to: url,
                colorSpace: colorSpace,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
            )
        }
    }

    private func crop(_ image: CIImage, to aspect: CropAspect) -> CIImage {
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

    private func normalize(_ channel: [Double]) -> [Double] {
        let peak = channel.max() ?? 0
        guard peak > 0 else { return channel }
        return channel.map { $0 / peak }
    }
}
