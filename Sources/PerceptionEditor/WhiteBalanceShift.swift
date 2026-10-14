import CoreImage
import Foundation

/// A fast stand-in for a RAW re-decode at a different white balance temperature.
///
/// Decoding a RAW at a new temperature costs about 0.3–0.5 s whatever the output size. While a
/// slider moves, the photo's as-shot decode is shifted instead: a Bradford chromatic adaptation in
/// linear sRGB from the as-shot illuminant to the requested one, treating both as points on the
/// Planckian locus. On a real S5 file this lands within a few levels out of 255 of the true decode
/// (3–8 typically, 13 at 2600 K), so it is a preview only; the exact decode replaces it when the
/// slider settles. Tint is not modeled.
enum WhiteBalanceShift {
    typealias Matrix = [[Double]]

    static let identity: Matrix = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
    private static let d65 = [0.95047, 1.0, 1.08883]
    private static let bradford: Matrix = [[0.8951, 0.2664, -0.1614], [-0.7502, 1.7135, 0.0367], [0.0389, -0.0685, 1.0296]]
    private static let srgbToXYZ: Matrix = [[0.4124564, 0.3575761, 0.1804375], [0.2126729, 0.7151522, 0.0721750], [0.0193339, 0.1191920, 0.9503041]]

    /// Only a temperature change on an otherwise default RAW setup can be shifted from the as-shot decode.
    nonisolated static func canShift(_ raw: RawSettings) -> Bool {
        guard raw.temperature != nil, raw.tint == nil else { return false }
        var withoutTemperature = raw
        withoutTemperature.temperature = nil
        return withoutTemperature == RawSettings()
    }

    /// Linear-sRGB matrix taking a decode made at `source` kelvin to what a decode at `target` would look like.
    nonisolated static func matrix(from source: Double, to target: Double) -> Matrix {
        let toTarget = adaptation(from: whitePoint(target), to: d65)
        let fromSource = adaptation(from: d65, to: whitePoint(source))
        let xyz = multiply(toTarget, fromSource)
        return multiply(inverse(srgbToXYZ), multiply(xyz, srgbToXYZ))
    }

    nonisolated static func apply(to image: CIImage, from source: Double, to target: Double) -> CIImage {
        let m = matrix(from: source, to: target)
        guard let filter = CIFilter(name: "CIColorMatrix", parameters: [
            kCIInputImageKey: image,
            "inputRVector": CIVector(x: m[0][0], y: m[0][1], z: m[0][2], w: 0),
            "inputGVector": CIVector(x: m[1][0], y: m[1][1], z: m[1][2], w: 0),
            "inputBVector": CIVector(x: m[2][0], y: m[2][1], z: m[2][2], w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ]), let output = filter.outputImage else { return image }
        return output
    }

    /// Planckian-locus chromaticity (Kim et al.) as XYZ with Y = 1, valid for 1667–25000 K.
    nonisolated static func whitePoint(_ kelvin: Double) -> [Double] {
        let t = min(25000, max(2000, kelvin))
        let t2 = t * t, t3 = t * t * t
        let x = t <= 4000
            ? -0.2661239e9 / t3 - 0.2343589e6 / t2 + 0.8776956e3 / t + 0.179910
            : -3.0258469e9 / t3 + 2.1070379e6 / t2 + 0.2226347e3 / t + 0.240390
        let y: Double
        if t <= 2222 {
            y = -1.1063814 * x * x * x - 1.34811020 * x * x + 2.18555832 * x - 0.20219683
        } else if t <= 4000 {
            y = -0.9549476 * x * x * x - 1.37418593 * x * x + 2.09137015 * x - 0.16748867
        } else {
            y = 3.0817580 * x * x * x - 5.87338670 * x * x + 3.75112997 * x - 0.37001483
        }
        return [x / y, 1, (1 - x - y) / y]
    }

    private nonisolated static func adaptation(from: [Double], to: [Double]) -> Matrix {
        let source = apply(bradford, from), destination = apply(bradford, to)
        let scale: Matrix = [[destination[0] / source[0], 0, 0], [0, destination[1] / source[1], 0], [0, 0, destination[2] / source[2]]]
        return multiply(inverse(bradford), multiply(scale, bradford))
    }

    nonisolated static func multiply(_ a: Matrix, _ b: Matrix) -> Matrix {
        (0 ..< 3).map { i in (0 ..< 3).map { j in (0 ..< 3).reduce(0.0) { $0 + a[i][$1] * b[$1][j] } } }
    }

    private nonisolated static func apply(_ m: Matrix, _ v: [Double]) -> [Double] {
        (0 ..< 3).map { i in (0 ..< 3).reduce(0.0) { $0 + m[i][$1] * v[$1] } }
    }

    nonisolated static func inverse(_ m: Matrix) -> Matrix {
        let a = m[0][0], b = m[0][1], c = m[0][2], d = m[1][0], e = m[1][1], f = m[1][2], g = m[2][0], h = m[2][1], i = m[2][2]
        let det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        return [[(e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det],
                [(f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det],
                [(d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det]]
    }
}
