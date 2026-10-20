import CoreImage
import Foundation
@testable import PerceptionEditor

/// Renders a fixture through the production color graph to an RGBA16 sRGB-encoded buffer.
enum IQRender {
    static let outputSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// One context for every image-quality render, so the suite does not create a new GPU context per call.
    /// `nonisolated(unsafe)`: `CIContext` is not `Sendable` on every SDK (the other test fixtures work around
    /// the same thing), and Core Image documents a context as safe to use from several threads.
    nonisolated(unsafe) static let sharedContext = CIContext(options: [.workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])

    static func pixels(of image: CIImage, context: CIContext = IQRender.sharedContext) -> [UInt16] {
        let rect = image.extent.integral
        let width = Int(rect.width), height = Int(rect.height)
        var buffer = [UInt16](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &buffer, rowBytes: width * 8, bounds: rect, format: .RGBA16, colorSpace: outputSpace)
        return buffer
    }

    static func render(_ source: CIImage, _ adjustments: PhotoAdjustments, highlightRolloff: Bool = false) -> [UInt16] {
        pixels(of: MediaColorRenderer.render(source, adjustments: adjustments, includesGeometry: false,
                                             highlightRolloff: highlightRolloff))
    }
}

/// Named edit recipes. Process version 1 recipes are frozen: their goldens must not change.
enum IQRecipes {
    static let all: [(name: String, adjustments: PhotoAdjustments, rolloff: Bool)] = {
        func make(_ edit: (inout PhotoAdjustments) -> Void) -> PhotoAdjustments {
            var value = PhotoAdjustments(); value.processVersion = 1; edit(&value); return value
        }
        return [
            ("neutral", make { _ in }, false),
            ("exposurePlus1", make { $0.exposure = 1 }, false),
            ("contrastPlus", make { $0.contrast = 0.4 }, false),
            ("highlightsMinusShadowsPlus", make { $0.highlights = -0.6; $0.shadows = 0.5 }, false),
            ("saturationVibrance", make { $0.saturation = 0.4; $0.vibrance = 0.5 }, false),
            ("warmTint", make { $0.temperature = 0.3; $0.tint = -0.2 }, false),
            ("rawRolloff", make { $0.exposure = 0.5; $0.highlights = -0.4 }, true),
            ("sharpen", make { $0.sharpness = 0.6 }, false),
        ]
    }()
}

extension IQRender {
    /// A photo through the geometry-aware photo path, as the preview and export take it.
    static func photo(_ source: CIImage, _ adjustments: PhotoAdjustments, raw: Bool = false) -> [UInt16] {
        pixels(of: MediaColorRenderer.render(source, adjustments: adjustments, includesGeometry: true, highlightRolloff: raw))
    }

    static func version2(_ edit: (inout PhotoAdjustments) -> Void = { _ in }) -> PhotoAdjustments {
        var value = PhotoAdjustments()
        value.processVersion = 2
        edit(&value)
        return value
    }

    /// Linear-light sRGB of one pixel of an RGBA16 sRGB-encoded buffer.
    static func linear(_ buffer: [UInt16], width: Int, x: Int, y: Int) -> (r: Double, g: Double, b: Double) {
        let index = (y * width + x) * 4
        return (IQMetrics.srgbToLinear(Double(buffer[index]) / 65535),
                IQMetrics.srgbToLinear(Double(buffer[index + 1]) / 65535),
                IQMetrics.srgbToLinear(Double(buffer[index + 2]) / 65535))
    }

    static func luma(_ pixel: (r: Double, g: Double, b: Double)) -> Double {
        0.2126 * pixel.r + 0.7152 * pixel.g + 0.0722 * pixel.b
    }
}
