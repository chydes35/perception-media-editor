import Foundation

/// Perceptual image metrics for the image-quality tests. Inputs are sRGB-encoded 0…1 triples
/// unless a name says otherwise. Pure Swift on the CPU, so results do not depend on the GPU.
enum IQMetrics {
    // MARK: Color conversion

    static func srgbToLinear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    static func linearToSRGB(_ value: Double) -> Double {
        value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
    }

    /// Linear Rec.709 / sRGB primaries to CIE XYZ (D65).
    static func xyz(fromLinear r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        (0.4124564 * r + 0.3575761 * g + 0.1804375 * b,
         0.2126729 * r + 0.7151522 * g + 0.0721750 * b,
         0.0193339 * r + 0.1191920 * g + 0.9503041 * b)
    }

    static func lab(fromSRGB r: Double, _ g: Double, _ b: Double) -> (L: Double, a: Double, b: Double) {
        let (x, y, z) = xyz(fromLinear: srgbToLinear(r), srgbToLinear(g), srgbToLinear(b))
        func f(_ t: Double) -> Double { t > 216.0 / 24389.0 ? cbrt(t) : (24389.0 / 27.0 * t + 16) / 116 }
        let fx = f(x / 0.95047), fy = f(y), fz = f(z / 1.08883)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// Oklab → OkLCh (lightness, chroma, hue in degrees) from linear sRGB.
    static func oklch(fromLinear r: Double, _ g: Double, _ b: Double) -> (L: Double, C: Double, h: Double) {
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        var hue = atan2(bb, a) * 180 / .pi
        if hue < 0 { hue += 360 }
        return (L, hypot(a, bb), hue)
    }

    // MARK: ΔE2000

    static func deltaE2000(_ c1: (L: Double, a: Double, b: Double), _ c2: (L: Double, a: Double, b: Double)) -> Double {
        let rad = Double.pi / 180
        let c1ab = hypot(c1.a, c1.b), c2ab = hypot(c2.a, c2.b)
        let cMean = (c1ab + c2ab) / 2
        let g = 0.5 * (1 - sqrt(pow(cMean, 7) / (pow(cMean, 7) + pow(25.0, 7))))
        let a1 = (1 + g) * c1.a, a2 = (1 + g) * c2.a
        let cp1 = hypot(a1, c1.b), cp2 = hypot(a2, c2.b)
        func hue(_ b: Double, _ a: Double) -> Double {
            if a == 0 && b == 0 { return 0 }
            let h = atan2(b, a) / rad
            return h < 0 ? h + 360 : h
        }
        let hp1 = hue(c1.b, a1), hp2 = hue(c2.b, a2)
        let dL = c2.L - c1.L, dC = cp2 - cp1
        var dh = 0.0
        if cp1 * cp2 != 0 {
            dh = hp2 - hp1
            if dh > 180 { dh -= 360 } else if dh < -180 { dh += 360 }
        }
        let dH = 2 * sqrt(cp1 * cp2) * sin(dh / 2 * rad)
        let lMean = (c1.L + c2.L) / 2, cpMean = (cp1 + cp2) / 2
        var hMean = hp1 + hp2
        if cp1 * cp2 != 0 {
            if abs(hp1 - hp2) > 180 { hMean += hp1 + hp2 < 360 ? 360 : -360 }
            hMean /= 2
        }
        let t = 1 - 0.17 * cos((hMean - 30) * rad) + 0.24 * cos(2 * hMean * rad)
            + 0.32 * cos((3 * hMean + 6) * rad) - 0.20 * cos((4 * hMean - 63) * rad)
        let dTheta = 30 * exp(-pow((hMean - 275) / 25, 2))
        let rc = 2 * sqrt(pow(cpMean, 7) / (pow(cpMean, 7) + pow(25.0, 7)))
        let sl = 1 + 0.015 * pow(lMean - 50, 2) / sqrt(20 + pow(lMean - 50, 2))
        let sc = 1 + 0.045 * cpMean, sh = 1 + 0.015 * cpMean * t
        let rt = -sin(2 * dTheta * rad) * rc
        return sqrt(pow(dL / sl, 2) + pow(dC / sc, 2) + pow(dH / sh, 2) + rt * (dC / sc) * (dH / sh))
    }

    // MARK: Image comparison

    struct Summary: Sendable {
        var meanDeltaE = 0.0
        var p95DeltaE = 0.0
        var maxDeltaE = 0.0
        var maxCodeDifference = 0
    }

    /// Compares two RGBA16 sRGB-encoded buffers of the same size.
    static func compare(_ a: [UInt16], _ b: [UInt16]) -> Summary {
        precondition(a.count == b.count && a.count % 4 == 0, "buffers must match")
        var deltas: [Double] = []
        deltas.reserveCapacity(a.count / 4)
        var maxCode = 0
        for index in stride(from: 0, to: a.count, by: 4) {
            for channel in 0..<3 { maxCode = max(maxCode, abs(Int(a[index + channel]) - Int(b[index + channel]))) }
            let lab1 = lab(fromSRGB: Double(a[index]) / 65535, Double(a[index + 1]) / 65535, Double(a[index + 2]) / 65535)
            let lab2 = lab(fromSRGB: Double(b[index]) / 65535, Double(b[index + 1]) / 65535, Double(b[index + 2]) / 65535)
            deltas.append(deltaE2000(lab1, lab2))
        }
        deltas.sort()
        let mean = deltas.reduce(0, +) / Double(max(1, deltas.count))
        return Summary(meanDeltaE: mean,
                       p95DeltaE: deltas[min(deltas.count - 1, Int(Double(deltas.count) * 0.95))],
                       maxDeltaE: deltas.last ?? 0,
                       maxCodeDifference: maxCode)
    }

    /// Rec. 709 luma of every pixel of an RGBA16 buffer, on the buffer's own (encoded) values. Written as a
    /// loop with typed locals: the one-expression form was too much for CI's older type-checker.
    static func lumas(_ buffer: [UInt16]) -> [Double] {
        var result: [Double] = []
        result.reserveCapacity(buffer.count / 4)
        for index in stride(from: 0, to: buffer.count, by: 4) {
            let r: Double = Double(buffer[index]) / 65535
            let g: Double = Double(buffer[index + 1]) / 65535
            let b: Double = Double(buffer[index + 2]) / 65535
            result.append(0.2126 * r + 0.7152 * g + 0.0722 * b)
        }
        return result
    }

    /// Global SSIM on luma (single window), good enough to catch structure loss in regression tests.
    static func ssimLuma(_ a: [UInt16], _ b: [UInt16]) -> Double {
        let x = lumas(a), y = lumas(b)
        let n = Double(x.count)
        let mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
        var vx = 0.0, vy = 0.0, cov = 0.0
        for index in 0..<x.count {
            vx += (x[index] - mx) * (x[index] - mx)
            vy += (y[index] - my) * (y[index] - my)
            cov += (x[index] - mx) * (y[index] - my)
        }
        vx /= n; vy /= n; cov /= n
        let c1 = 0.01 * 0.01, c2 = 0.03 * 0.03
        return ((2 * mx * my + c1) * (2 * cov + c2)) / ((mx * mx + my * my + c1) * (vx + vy + c2))
    }

    /// Smallest angle between two hues, in degrees.
    static func hueDifference(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return d > 180 ? 360 - d : d
    }
}
