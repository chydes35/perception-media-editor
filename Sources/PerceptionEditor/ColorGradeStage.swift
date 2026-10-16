import CoreImage
import Foundation
import Metal

/// Applies a clip's color adjustments with the same Core Image graph photos use
/// (`MediaColorRenderer`), in half float on the compositor's own command buffer.
///
/// Frames are tagged with Apple's Rec. 709 video color space (`CoreMedia709`), the one AVFoundation
/// gave Core Image under the old `AVVideoComposition` handler, so a Rec. 709 clip keeps its look.
/// Plain ITU-R 709 linearizes differently (Apple video uses a gamma of about 1.96) and measured
/// 10 of 255 levels away on a graded frame; CoreMedia709 measured 0.4.
final class ColorGradeStage: @unchecked Sendable {
    private let context: CIContext
    private let space: CGColorSpace

    init(queue: MTLCommandQueue) {
        space = CGColorSpace(name: CGColorSpace.coreMedia709) ?? CGColorSpace(name: CGColorSpace.itur_709)!
        context = CIContext(mtlCommandQueue: queue, options: [
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: false
        ])
    }

    /// Reads `input` and writes the graded frame into `output` (same size), both `rgba16Float`.
    /// Returns false when Core Image cannot wrap the texture.
    @discardableResult
    func grade(_ input: MTLTexture, adjustments: PhotoAdjustments, into output: MTLTexture, commandBuffer: MTLCommandBuffer) -> Bool {
        guard let wrapped = CIImage(mtlTexture: input, options: [.colorSpace: space]) else { return false }
        let bounds = CGRect(x: 0, y: 0, width: input.width, height: input.height)
        // Textures have a top-left origin and Core Image a bottom-left one: flip in, grade, flip out.
        let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(input.height))
        let upright = wrapped.transformed(by: flip)
        let graded = MediaColorRenderer.render(upright, adjustments: adjustments, includesGeometry: false)
            .cropped(to: bounds)
            .transformed(by: flip)
        context.render(graded, to: output, commandBuffer: commandBuffer, bounds: bounds, colorSpace: space)
        return true
    }
}
