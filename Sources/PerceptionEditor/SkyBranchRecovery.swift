import Foundation

/// Color recovery requires existing blue-sky evidence and semantic tree coverage.
/// It cannot create a sky selection in a photo for which inference finds no sky.
enum SkyBranchRecovery {
    static func recover(mask: [UInt8], rgba: [UInt8], trees: [UInt8], width: Int, height: Int) throws -> [UInt8] {
        guard width > 0, height > 0, mask.count == width * height,
              trees.count == mask.count, rgba.count == mask.count * 4 else { return mask }
        var red: Float = 0, green: Float = 0, blue: Float = 0
        var samples = 0, lastSkyRow = 0
        for y in 0..<height {
            if y % 128 == 0 { try Task.checkCancellation() }
            for x in 0..<width {
                let i = y * width + x, j = i * 4
                let r = Float(rgba[j]), g = Float(rgba[j + 1]), b = Float(rgba[j + 2])
                let sum = max(1, r + g + b)
                guard mask[i] >= 230, b >= 40, (b - r) / sum >= 0.06, (b - g) / sum >= 0.02 else { continue }
                red += r / sum; green += g / sum; blue += b
                samples += 1; lastSkyRow = y
            }
        }
        guard samples >= 24 else { return mask }
        red /= Float(samples); green /= Float(samples); blue /= Float(samples)
        // Recovery stays near the existing sky's vertical band, not across the frame.
        let lastRow = min(height - 1, lastSkyRow + height / 10)
        var output = mask
        for y in 0...lastRow {
            if y % 128 == 0 { try Task.checkCancellation() }
            for x in 0..<width {
                let i = y * width + x, j = i * 4
                guard trees[i] >= 128 else { continue }
                let r = Float(rgba[j]), g = Float(rgba[j + 1]), b = Float(rgba[j + 2])
                let sum = max(1, r + g + b)
                guard b >= max(40, blue * 0.35), (b - r) / sum >= 0.06, (b - g) / sum >= 0.02 else { continue }
                let dr = r / sum - red, dg = g / sum - green
                let distance = sqrt(dr * dr + dg * dg)
                let confidence = min(1, max(0, (0.08 - distance) / 0.04))
                output[i] = max(mask[i], UInt8((confidence * 255).rounded()))
            }
        }
        return output
    }
}
