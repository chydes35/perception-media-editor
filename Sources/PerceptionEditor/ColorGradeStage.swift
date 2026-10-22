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
    /// Scene-linear Rec. 709 (sRGB primaries), unclamped: what OCIO's V-Log input transform writes.
    private let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    init(queue: MTLCommandQueue) {
        space = CGColorSpace(name: CGColorSpace.coreMedia709) ?? CGColorSpace(name: CGColorSpace.itur_709)!
        context = CIContext(mtlCommandQueue: queue, options: [
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: false
        ])
    }

    /// Releases Core Image's cached intermediates and kernels' state, for memory pressure.
    func clearCaches() {
        context.clearCaches()
    }

    /// Reads `input` and writes the graded frame into `output` (same size), both `rgba16Float`.
    /// With an `inputLUT`, the frame's values are code values: the LUT maps them first, and its
    /// output is then treated as Rec. 709. With `sceneLinear`, both frames hold scene-linear
    /// Rec. 709 instead (the OCIO path), which is Core Image's own working space, so nothing is
    /// converted on the way in or out. Returns false when Core Image cannot wrap the texture.
    @discardableResult
    func grade(
        _ input: MTLTexture, adjustments: PhotoAdjustments, inputLUT: ResolvedLUT? = nil, sceneLinear: Bool = false,
        into output: MTLTexture, commandBuffer: MTLCommandBuffer
    ) -> Bool {
        let space = sceneLinear ? linearSpace : self.space
        let bounds = CGRect(x: 0, y: 0, width: input.width, height: input.height)
        // Textures have a top-left origin and Core Image a bottom-left one: flip in, grade, flip out.
        let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(input.height))
        var image: CIImage
        if let inputLUT, !sceneLinear {
            // Untagged, so Core Image does not linearize the log values before the LUT sees them.
            guard let raw = CIImage(mtlTexture: input, options: [.colorSpace: NSNull()]),
                  let mapped = LUTKernel.apply(inputLUT.lut, cacheKey: inputLUT.hash, intensity: 1, to: raw.transformed(by: flip)),
                  let working = mapped.matchedToWorkingSpace(from: space) else { return false }
            image = working
        } else {
            guard let wrapped = CIImage(mtlTexture: input, options: [.colorSpace: space]) else { return false }
            image = wrapped.transformed(by: flip)
        }
        if !adjustments.isUntouched {
            image = MediaColorRenderer.render(image, adjustments: adjustments, includesGeometry: false)
        }
        context.render(image.cropped(to: bounds).transformed(by: flip), to: output, commandBuffer: commandBuffer, bounds: bounds, colorSpace: space)
        return true
    }
}
