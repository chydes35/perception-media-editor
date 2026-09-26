import CoreGraphics
import Foundation

// MARK: - Tone curve

struct CurvePoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
}

/// A tone curve through user-placed points, from (0, 0) to (1, 1). The curve between points
/// is monotone cubic (PCHIP), so it never overshoots or wobbles between the points the way an
/// ordinary spline can, and a curve that only ever rises stays rising.
struct ToneCurve: Codable, Equatable, Sendable {
    /// Points sorted by x. The first is always at x = 0 and the last at x = 1; their heights can move.
    var points: [CurvePoint]

    static let minimumGap = 0.02
    static let maximumPoints = 16

    static var linear: ToneCurve {
        ToneCurve(points: [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)])
    }

    var isLinear: Bool {
        points.count == 2 && abs(points[0].y) < 1e-6 && abs(points[1].y - 1) < 1e-6
    }

    /// Named starting points for the curve editor.
    static let presets: [(name: String, curve: ToneCurve)] = [
        ("Linear", .linear),
        ("Medium Contrast", ToneCurve(points: [
            CurvePoint(x: 0, y: 0), CurvePoint(x: 0.25, y: 0.20), CurvePoint(x: 0.75, y: 0.80), CurvePoint(x: 1, y: 1)
        ])),
        ("Strong Contrast", ToneCurve(points: [
            CurvePoint(x: 0, y: 0), CurvePoint(x: 0.25, y: 0.15), CurvePoint(x: 0.75, y: 0.85), CurvePoint(x: 1, y: 1)
        ])),
        ("Lift Shadows", ToneCurve(points: [
            CurvePoint(x: 0, y: 0), CurvePoint(x: 0.2, y: 0.28), CurvePoint(x: 1, y: 1)
        ])),
        ("Faded", ToneCurve(points: [
            CurvePoint(x: 0, y: 0.06), CurvePoint(x: 0.5, y: 0.5), CurvePoint(x: 1, y: 0.94)
        ]))
    ]

    /// The curve's height at `x`.
    func evaluate(_ x: Double) -> Double {
        let pts = points
        guard pts.count >= 2 else { return min(1, max(0, x)) }
        if x <= pts[0].x { return pts[0].y }
        if x >= pts[pts.count - 1].x { return pts[pts.count - 1].y }

        let slopes = tangents()
        var k = 0
        while k < pts.count - 2, x > pts[k + 1].x { k += 1 }

        let h = pts[k + 1].x - pts[k].x
        let t = (x - pts[k].x) / h
        let t2 = t * t
        let t3 = t2 * t
        let value = (2 * t3 - 3 * t2 + 1) * pts[k].y
            + (t3 - 2 * t2 + t) * h * slopes[k]
            + (-2 * t3 + 3 * t2) * pts[k + 1].y
            + (t3 - t2) * h * slopes[k + 1]
        return min(1, max(0, value))
    }

    /// `samples` evenly spaced heights, for a 1D lookup table.
    func lookupTable(samples: Int = 256) -> [Float] {
        guard samples >= 2 else { return [] }
        let slopes = tangents()
        var table = [Float](repeating: 0, count: samples)
        var k = 0
        for i in 0 ..< samples {
            let x = Double(i) / Double(samples - 1)
            while k < points.count - 2, x > points[k + 1].x { k += 1 }
            table[i] = Float(evaluate(x, segment: k, slopes: slopes))
        }
        return table
    }

    private func evaluate(_ x: Double, segment k: Int, slopes: [Double]) -> Double {
        let pts = points
        guard pts.count >= 2 else { return x }
        if x <= pts[0].x { return pts[0].y }
        if x >= pts[pts.count - 1].x { return pts[pts.count - 1].y }
        let h = pts[k + 1].x - pts[k].x
        let t = (x - pts[k].x) / h
        let t2 = t * t
        let t3 = t2 * t
        let value = (2 * t3 - 3 * t2 + 1) * pts[k].y
            + (t3 - 2 * t2 + t) * h * slopes[k]
            + (-2 * t3 + 3 * t2) * pts[k + 1].y
            + (t3 - t2) * h * slopes[k + 1]
        return min(1, max(0, value))
    }

    /// Fritsch–Carlson tangents: zero at local extremes, weighted harmonic means elsewhere.
    private func tangents() -> [Double] {
        let n = points.count
        guard n >= 2 else { return [] }
        var delta = [Double](repeating: 0, count: n - 1)
        var h = [Double](repeating: 0, count: n - 1)
        for k in 0 ..< n - 1 {
            h[k] = max(1e-9, points[k + 1].x - points[k].x)
            delta[k] = (points[k + 1].y - points[k].y) / h[k]
        }
        if n == 2 { return [delta[0], delta[0]] }

        var m = [Double](repeating: 0, count: n)
        m[0] = delta[0]
        m[n - 1] = delta[n - 2]
        for k in 1 ..< n - 1 {
            if delta[k - 1] * delta[k] <= 0 {
                m[k] = 0
            } else {
                let w1 = 2 * h[k] + h[k - 1]
                let w2 = h[k] + 2 * h[k - 1]
                m[k] = (w1 + w2) / (w1 / delta[k - 1] + w2 / delta[k])
            }
        }
        return m
    }

    // MARK: Editing

    /// Moves a point, keeping it between its neighbors. The end points only move vertically.
    mutating func movePoint(at index: Int, to target: CGPoint) {
        guard points.indices.contains(index) else { return }
        let y = min(1, max(0, Double(target.y)))
        if index == 0 || index == points.count - 1 {
            points[index].y = y
            return
        }
        let low = points[index - 1].x + Self.minimumGap
        let high = points[index + 1].x - Self.minimumGap
        points[index].x = min(max(Double(target.x), low), max(low, high))
        points[index].y = y
    }

    /// Adds a point and returns its index, or nil if the curve is full or another point is too close.
    @discardableResult
    mutating func addPoint(x: Double, y: Double) -> Int? {
        guard points.count < Self.maximumPoints else { return nil }
        let x = min(1, max(0, x))
        guard !points.contains(where: { abs($0.x - x) < Self.minimumGap }) else { return nil }
        let index = points.firstIndex(where: { $0.x > x }) ?? points.count
        points.insert(CurvePoint(x: x, y: min(1, max(0, y))), at: index)
        return index
    }

    /// Removes an interior point. The end points cannot be removed.
    mutating func removePoint(at index: Int) {
        guard index > 0, index < points.count - 1 else { return }
        points.remove(at: index)
    }

    /// The index of the point nearest `target` within `radius` (in curve units), if any.
    func nearestPoint(to target: CGPoint, radius: Double) -> Int? {
        var best: (index: Int, distance: Double)?
        for (index, point) in points.enumerated() {
            let distance = hypot(point.x - Double(target.x), point.y - Double(target.y))
            if distance <= radius, distance < (best?.distance ?? .infinity) {
                best = (index, distance)
            }
        }
        return best?.index
    }
}

/// The master (RGB) curve plus one per color channel. A nil curve is a straight line.
struct ToneCurves: Codable, Equatable, Sendable {
    var rgb: ToneCurve?
    var red: ToneCurve?
    var green: ToneCurve?
    var blue: ToneCurve?

    var isNeutral: Bool {
        [rgb, red, green, blue].allSatisfy { $0 == nil || $0?.isLinear == true }
    }

    enum Channel: String, CaseIterable, Identifiable, Sendable {
        case rgb = "RGB"
        case red = "R"
        case green = "G"
        case blue = "B"

        var id: String { rawValue }
    }

    subscript(channel: Channel) -> ToneCurve? {
        get {
            switch channel {
            case .rgb: rgb
            case .red: red
            case .green: green
            case .blue: blue
            }
        }
        set {
            let stored = newValue?.isLinear == true ? nil : newValue
            switch channel {
            case .rgb: rgb = stored
            case .red: red = stored
            case .green: green = stored
            case .blue: blue = stored
            }
        }
    }
}

// MARK: - HSL

enum HSLBand: String, CaseIterable, Identifiable, Sendable {
    case red, orange, yellow, green, aqua, blue, purple, magenta

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// The hue (degrees) at the middle of each band, as in Lightroom's HSL panel.
    var centerHue: Double {
        switch self {
        case .red: 0
        case .orange: 30
        case .yellow: 60
        case .green: 120
        case .aqua: 180
        case .blue: 240
        case .purple: 270
        case .magenta: 300
        }
    }
}

struct HSLBandAdjustment: Codable, Equatable, Sendable {
    /// −1 … 1, worth up to ±30° of hue.
    var hue = 0.0
    /// −1 (gray) … 1 (twice as vivid).
    var saturation = 0.0
    /// −1 … 1, worth up to ±0.25 of lightness.
    var luminance = 0.0

    var isNeutral: Bool { hue == 0 && saturation == 0 && luminance == 0 }
}

struct HSLAdjustments: Codable, Equatable, Sendable {
    var red = HSLBandAdjustment()
    var orange = HSLBandAdjustment()
    var yellow = HSLBandAdjustment()
    var green = HSLBandAdjustment()
    var aqua = HSLBandAdjustment()
    var blue = HSLBandAdjustment()
    var purple = HSLBandAdjustment()
    var magenta = HSLBandAdjustment()

    var isNeutral: Bool {
        HSLBand.allCases.allSatisfy { self[$0].isNeutral }
    }

    subscript(band: HSLBand) -> HSLBandAdjustment {
        get {
            switch band {
            case .red: red
            case .orange: orange
            case .yellow: yellow
            case .green: green
            case .aqua: aqua
            case .blue: blue
            case .purple: purple
            case .magenta: magenta
            }
        }
        set {
            switch band {
            case .red: red = newValue
            case .orange: orange = newValue
            case .yellow: yellow = newValue
            case .green: green = newValue
            case .aqua: aqua = newValue
            case .blue: blue = newValue
            case .purple: purple = newValue
            case .magenta: magenta = newValue
            }
        }
    }

    /// The adjustment for a hue, blended smoothly between the two nearest bands.
    func adjustment(atHue hue: Double) -> HSLBandAdjustment {
        let bands = HSLBand.allCases
        let wrapped = hue.truncatingRemainder(dividingBy: 360) < 0 ? hue + 360 : hue.truncatingRemainder(dividingBy: 360)

        var lowerIndex = bands.count - 1
        for (index, band) in bands.enumerated() where band.centerHue <= wrapped { lowerIndex = index }
        let lower = bands[lowerIndex]
        let upper = bands[(lowerIndex + 1) % bands.count]

        let lowerCenter = lower.centerHue
        var upperCenter = upper.centerHue
        if upperCenter <= lowerCenter { upperCenter += 360 }
        let position = wrapped >= lowerCenter ? wrapped : wrapped + 360
        let t = min(1, max(0, (position - lowerCenter) / (upperCenter - lowerCenter)))
        let eased = t * t * (3 - 2 * t)

        let a = self[lower], b = self[upper]
        return HSLBandAdjustment(
            hue: a.hue + (b.hue - a.hue) * eased,
            saturation: a.saturation + (b.saturation - a.saturation) * eased,
            luminance: a.luminance + (b.luminance - a.luminance) * eased
        )
    }
}

// MARK: - Rendering data

enum ColorGrading {
    /// Nodes per side of the HSL color cube. 48 keeps interpolation error under 2 levels of 255
    /// (33 reaches 4) and takes about 5 ms to build.
    static let cubeDimension = 48

    /// Curve lookup data for Core Image's color-curves filter (three float channels per sample),
    /// or nil when every curve is a straight line so the filter can be skipped.
    static func curveData(_ curves: ToneCurves, samples: Int = 256) -> Data? {
        guard !curves.isNeutral else { return nil }
        let master = (curves.rgb ?? .linear).lookupTable(samples: samples)
        let channels = [curves.red, curves.green, curves.blue].map { ($0 ?? .linear).lookupTable(samples: samples) }

        var values = [Float]()
        values.reserveCapacity(samples * 3)
        for i in 0 ..< samples {
            for channel in channels {
                // The channel curve acts on the result of the master curve.
                let masterValue = Double(master[i])
                let position = masterValue * Double(samples - 1)
                let lower = min(samples - 2, max(0, Int(position)))
                let fraction = Float(position - Double(lower))
                values.append(channel[lower] + (channel[lower + 1] - channel[lower]) * fraction)
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// One color after HSL adjustments. Inputs and outputs are gamma-encoded RGB in 0…1.
    static func applyHSL(_ hsl: HSLAdjustments, r: Double, g: Double, b: Double) -> (r: Double, g: Double, b: Double) {
        let maximum = max(r, g, b)
        let minimum = min(r, g, b)
        let chroma = maximum - minimum
        // Grays have no hue, so they are left alone; the effect fades in as color gets stronger.
        guard chroma > 1e-6 else { return (r, g, b) }

        var (h, s, l) = rgbToHSL(r, g, b, maximum: maximum, minimum: minimum)
        let strength = smoothstep(0.02, 0.20, chroma)
        let adjustment = hsl.adjustment(atHue: h)

        h += adjustment.hue * 30 * strength
        s = min(1, max(0, s * (1 + adjustment.saturation * strength)))
        l = min(1, max(0, l + adjustment.luminance * 0.25 * strength))
        return hslToRGB(h, s, l)
    }

    /// A color cube (RGBA floats, red varying fastest) that applies `hsl`, for Core Image.
    static func hslCube(_ hsl: HSLAdjustments, dimension: Int = ColorGrading.cubeDimension) -> Data {
        if let cached = HSLCubeCache.shared.data(for: hsl, dimension: dimension) { return cached }

        let n = dimension
        var values = [Float](repeating: 0, count: n * n * n * 4)
        var index = 0
        for blue in 0 ..< n {
            for green in 0 ..< n {
                for red in 0 ..< n {
                    let result = applyHSL(
                        hsl,
                        r: Double(red) / Double(n - 1),
                        g: Double(green) / Double(n - 1),
                        b: Double(blue) / Double(n - 1)
                    )
                    values[index] = Float(result.r)
                    values[index + 1] = Float(result.g)
                    values[index + 2] = Float(result.b)
                    values[index + 3] = 1
                    index += 4
                }
            }
        }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        HSLCubeCache.shared.store(data, for: hsl, dimension: dimension)
        return data
    }

    // MARK: Color math

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }

    static func rgbToHSL(
        _ r: Double, _ g: Double, _ b: Double,
        maximum: Double? = nil, minimum: Double? = nil
    ) -> (h: Double, s: Double, l: Double) {
        let maximum = maximum ?? max(r, g, b)
        let minimum = minimum ?? min(r, g, b)
        let l = (maximum + minimum) / 2
        let d = maximum - minimum
        guard d > 1e-12 else { return (0, 0, l) }

        let s = l > 0.5 ? d / (2 - maximum - minimum) : d / (maximum + minimum)
        var h: Double
        if maximum == r {
            h = (g - b) / d + (g < b ? 6 : 0)
        } else if maximum == g {
            h = (b - r) / d + 2
        } else {
            h = (r - g) / d + 4
        }
        h *= 60
        return (h, s, l)
    }

    static func hslToRGB(_ hue: Double, _ s: Double, _ l: Double) -> (r: Double, g: Double, b: Double) {
        guard s > 1e-12 else { return (l, l, l) }
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q

        func channel(_ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return (channel(h + 1.0 / 3), channel(h), channel(h - 1.0 / 3))
    }
}

/// Remembers the last few cubes, so moving an unrelated slider does not rebuild them.
private final class HSLCubeCache: @unchecked Sendable {
    static let shared = HSLCubeCache()

    private struct Entry {
        var hsl: HSLAdjustments
        var dimension: Int
        var data: Data
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func data(for hsl: HSLAdjustments, dimension: Int) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return entries.first { $0.hsl == hsl && $0.dimension == dimension }?.data
    }

    func store(_ data: Data, for hsl: HSLAdjustments, dimension: Int) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll { $0.hsl == hsl && $0.dimension == dimension }
        entries.append(Entry(hsl: hsl, dimension: dimension, data: data))
        if entries.count > 4 { entries.removeFirst(entries.count - 4) }
    }
}
