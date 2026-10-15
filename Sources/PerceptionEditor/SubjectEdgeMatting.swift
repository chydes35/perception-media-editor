import CoreImage
import Foundation

/// Refines a subject mask near its edge by local color sampling: in a thin band around the
/// mask boundary, each pixel's opacity is its position on the line between the nearby
/// foreground color and the nearby background color. Flat or ambiguous areas keep the
/// original weight, so confident interiors and exteriors never change.
enum SubjectEdgeMatting {
    struct Parameters: Sendable {
        /// Half-width of the unknown band, in pixels of the working image.
        var band = 10
        /// Window for the foreground/background color estimates.
        var window = 14
        /// Minimum foreground/background color distance (0...1 per channel norm) to trust a matte.
        var minContrast: Float = 0.12
        /// Mask weight at or above which a pixel counts as certain foreground / below as certain background.
        var foregroundThreshold: Float = 0.97
        var backgroundThreshold: Float = 0.03
        /// Also examine pixels the model scored as background, within the band, so it can recover
        /// wisps the model missed. Texture can fake a wisp, so such pixels need strong evidence:
        /// they keep zero unless the smoothed matte exceeds `rescueFloor`, then ramp to 1.
        var rescueMissed = true
        var rescueFloor: Float = 0.5
    }

    /// `rgb` is width*height*3 floats in 0...1; `mask` is width*height floats in 0...1.
    static func refine(mask: [Float], rgb: [Float], width: Int, height: Int,
                       parameters: Parameters = Parameters()) -> [Float] {
        let n = width * height
        guard width > 0, height > 0, mask.count == n, rgb.count == n * 3 else { return mask }
        let p = parameters

        var isFG = [Float](repeating: 0, count: n)
        for i in 0 ..< n where mask[i] >= p.foregroundThreshold { isFG[i] = 1 }
        // Unknown band: everything within `band` pixels of certain foreground that is not itself
        // certain foreground, including pixels the model scored 0 (it can miss wisps entirely).
        // Background color is sampled only beyond the band, where the model's 0 can be trusted.
        let nearFG = boxMean(isFG, width, height, p.band)
        var isBG = [Float](repeating: 0, count: n)
        for i in 0 ..< n where mask[i] <= p.backgroundThreshold && nearFG[i] <= 0.0001 { isBG[i] = 1 }
        let nearBG = boxMean(isBG, width, height, p.band + p.window)
        let reach = p.band + p.window
        let weightsFG = boxMean(isFG, width, height, reach), weightsBG = boxMean(isBG, width, height, reach)
        var fgSum = [Float](repeating: 0, count: n * 3), bgSum = [Float](repeating: 0, count: n * 3)
        for c in 0 ..< 3 {
            var fc = [Float](repeating: 0, count: n), bc = [Float](repeating: 0, count: n)
            for i in 0 ..< n { fc[i] = isFG[i] * rgb[i * 3 + c]; bc[i] = isBG[i] * rgb[i * 3 + c] }
            let f = boxMean(fc, width, height, reach), b = boxMean(bc, width, height, reach)
            for i in 0 ..< n { fgSum[i * 3 + c] = f[i]; bgSum[i * 3 + c] = b[i] }
        }
        var out = mask
        var alphas = [Float](repeating: -1, count: n)
        for i in 0 ..< n where nearFG[i] > 0.0001 && nearBG[i] > 0.0001 && isFG[i] == 0 {
            guard weightsFG[i] > 0.002, weightsBG[i] > 0.002 else { continue }
            var d2: Float = 0, dot: Float = 0
            for c in 0 ..< 3 {
                let f = fgSum[i * 3 + c] / weightsFG[i], b = bgSum[i * 3 + c] / weightsBG[i]
                let diff = f - b, cb = rgb[i * 3 + c] - b
                d2 += diff * diff; dot += cb * diff
            }
            guard d2 >= p.minContrast * p.minContrast else { continue }
            alphas[i] = min(1, max(0, dot / d2))
        }
        // Isolated texture hits are not wisps: judge rescued pixels on a lightly smoothed matte.
        var known = [Float](repeating: 0, count: n), value = [Float](repeating: 0, count: n)
        for i in 0 ..< n where alphas[i] >= 0 { known[i] = 1; value[i] = alphas[i] }
        let smoothValue = boxMean(value, width, height, 1), smoothKnown = boxMean(known, width, height, 1)
        for i in 0 ..< n where alphas[i] >= 0 {
            if mask[i] > p.backgroundThreshold {
                out[i] = alphas[i]
            } else if p.rescueMissed, smoothKnown[i] > 0 {
                let smooth = smoothValue[i] / smoothKnown[i]
                out[i] = min(1, max(0, (smooth - p.rescueFloor) / (1 - p.rescueFloor)))
            }
        }
        return out
    }

    private static func boxMean(_ values: [Float], _ width: Int, _ height: Int, _ radius: Int) -> [Float] {
        SkyEdgeRefiner.boxMean(values, width: width, height: height, radius: radius)
    }
}

extension SubjectEdgeMatting {
    /// Working size for the matte; memory stays near 40 MB regardless of the photo.
    static let workingDimension: CGFloat = 1536

    /// A source photo reduced once to `workingDimension`, shared by every candidate of one analysis.
    struct Source {
        let rgb: [Float]
        let width: Int
        let height: Int

        init?(image: CIImage, context: CIContext) {
            let extent = image.extent
            guard extent.width > 0, extent.height > 0 else { return nil }
            let scale = min(1, workingDimension / max(extent.width, extent.height))
            let size = CGSize(width: (extent.width * scale).rounded(), height: (extent.height * scale).rounded())
            guard size.width >= 1, size.height >= 1 else { return nil }
            let scaled = image
                .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
                .transformed(by: CGAffineTransform(scaleX: size.width / extent.width, y: size.height / extent.height))
            let w = Int(size.width), h = Int(size.height)
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            context.render(scaled, toBitmap: &bytes, rowBytes: w * 4, bounds: CGRect(origin: .zero, size: size),
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            var rgb = [Float](repeating: 0, count: w * h * 3)
            for i in 0 ..< w * h {
                rgb[i * 3] = Float(bytes[i * 4]) / 255
                rgb[i * 3 + 1] = Float(bytes[i * 4 + 1]) / 255
                rgb[i * 3 + 2] = Float(bytes[i * 4 + 2]) / 255
            }
            self.rgb = rgb; self.width = w; self.height = h
        }
    }

    /// Returns the candidate mask PNG refined against `source`, at the original PNG's size, or the
    /// original data if anything about it is unexpected.
    static func refinePNG(_ png: Data, source: Source, context: CIContext) -> Data {
        guard let mask = CIImage(data: png, options: [.colorSpace: NSNull()]),
              mask.extent.width > 0, mask.extent.height > 0 else { return png }
        let w = source.width, h = source.height
        let reduced = mask
            .transformed(by: CGAffineTransform(translationX: -mask.extent.minX, y: -mask.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(w) / mask.extent.width, y: CGFloat(h) / mask.extent.height))
        var bytes = [UInt8](repeating: 0, count: w * h)
        context.render(reduced, toBitmap: &bytes, rowBytes: w, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                       format: .L8, colorSpace: nil)
        var weights = [Float](repeating: 0, count: w * h)
        for i in 0 ..< w * h { weights[i] = Float(bytes[i]) / 255 }
        let refined = refine(mask: weights, rgb: source.rgb, width: w, height: h)
        for i in 0 ..< w * h { bytes[i] = UInt8(min(255, max(0, refined[i] * 255 + 0.5))) }
        let small = CIImage(bitmapData: Data(bytes), bytesPerRow: w, size: CGSize(width: w, height: h),
                            format: .L8, colorSpace: nil)
        let up = small
            .transformed(by: CGAffineTransform(scaleX: mask.extent.width / CGFloat(w), y: mask.extent.height / CGFloat(h)))
            .samplingLinear()
            .cropped(to: CGRect(origin: .zero, size: mask.extent.size))
        return (try? SubjectAnalyzer.encodeMask(up)) ?? png
    }
}
