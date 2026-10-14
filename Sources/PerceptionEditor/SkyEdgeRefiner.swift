import Foundation

/// Guided filtering fits the coarse sky weights to local image brightness boundaries. This
/// can improve tree/building edges but cannot reconstruct details the semantic model missed.
enum SkyEdgeRefiner {
    static func refine(mask: [Float], guide: [Float], width: Int, height: Int,
                       radius: Int, epsilon: Float) -> [Float] {
        guard width > 0, height > 0, mask.count == width * height, guide.count == mask.count,
              radius > 0, epsilon > 0 else { return mask }
        let meanI = boxMean(guide, width: width, height: height, radius: radius)
        let meanP = boxMean(mask, width: width, height: height, radius: radius)
        var variance = boxMean(guide.map { $0 * $0 }, width: width, height: height, radius: radius)
        var covariance = boxMean(zip(guide, mask).map { $0.0 * $0.1 }, width: width, height: height, radius: radius)
        for i in mask.indices {
            variance[i] = max(0, variance[i] - meanI[i] * meanI[i])
            covariance[i] -= meanI[i] * meanP[i]
        }
        // Reuse the variance/covariance storage for the fitted coefficients.
        for i in mask.indices {
            covariance[i] /= variance[i] + epsilon
            variance[i] = meanP[i] - covariance[i] * meanI[i]
        }
        let meanA = boxMean(covariance, width: width, height: height, radius: radius)
        let meanB = boxMean(variance, width: width, height: height, radius: radius)
        return mask.indices.map { min(1, max(0, meanA[$0] * guide[$0] + meanB[$0])) }
    }

    /// Two sliding-window passes, O(pixel count), with smaller windows at image borders.
    private static func boxMean(_ values: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        let r = min(radius, max(width, height))
        var horizontal = [Float](repeating: 0, count: values.count)
        for y in 0 ..< height {
            let row = y * width
            var sum: Float = 0
            for x in 0 ... min(r, width - 1) { sum += values[row + x] }
            for x in 0 ..< width {
                horizontal[row + x] = sum / Float(min(width - 1, x + r) - max(0, x - r) + 1)
                if x - r >= 0 { sum -= values[row + x - r] }
                if x + r + 1 < width { sum += values[row + x + r + 1] }
            }
        }
        var output = horizontal
        for x in 0 ..< width {
            var sum: Float = 0
            for y in 0 ... min(r, height - 1) { sum += horizontal[y * width + x] }
            for y in 0 ..< height {
                output[y * width + x] = sum / Float(min(height - 1, y + r) - max(0, y - r) + 1)
                if y - r >= 0 { sum -= horizontal[(y - r) * width + x] }
                if y + r + 1 < height { sum += horizontal[(y + r + 1) * width + x] }
            }
        }
        return output
    }
}
