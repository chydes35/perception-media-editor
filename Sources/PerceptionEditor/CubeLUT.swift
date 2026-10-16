import Foundation
import simd

enum CubeLUTError: LocalizedError, Equatable {
    case tooLarge(bytes: Int)
    case notText
    case missingSize
    case bothSizes
    case sizeOutOfRange(keyword: String, size: Int, range: ClosedRange<Int>)
    case badLine(number: Int, reason: String)
    case wrongRowCount(keyword: String, size: Int, expected: Int, found: Int)
    case invalidDomain

    var errorDescription: String? {
        switch self {
        case .tooLarge(let bytes):
            "The LUT file is \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)); LUTs over 64 MB are not read."
        case .notText: "The LUT file is not text."
        case .missingSize: "The LUT file has no LUT_3D_SIZE or LUT_1D_SIZE line."
        case .bothSizes: "The LUT file has both a LUT_1D_SIZE and a LUT_3D_SIZE (a shaper LUT), which is not supported."
        case .sizeOutOfRange(let keyword, let size, let range):
            "\(keyword) is \(size); it must be between \(range.lowerBound) and \(range.upperBound)."
        case .badLine(let number, let reason): "Line \(number): \(reason)"
        case .wrongRowCount(let keyword, let size, let expected, let found):
            "\(keyword) \(size) needs \(expected) rows of values; this file has \(found)."
        case .invalidDomain: "DOMAIN_MIN must be below DOMAIN_MAX for every channel."
        }
    }
}

/// A `.cube` lookup table (Adobe/Resolve format): a 3D table with red varying fastest, or a 1D
/// table per channel, with an input domain.
struct CubeLUT: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case threeD(size: Int)
        case oneD(size: Int)
    }

    static let maximumFileBytes = 64 * 1024 * 1024
    static let threeDSizes = 2 ... 65
    static let oneDSizes = 2 ... 65_536

    var title: String?
    var kind: Kind
    var domainMin = SIMD3<Float>(repeating: 0)
    var domainMax = SIMD3<Float>(repeating: 1)
    /// RGB triples: size³ of them for 3D (red fastest, then green, then blue), size for 1D.
    var values: [Float]

    init(contentsOf url: URL) throws {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size <= Self.maximumFileBytes else { throw CubeLUTError.tooLarge(bytes: size) }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw CubeLUTError.notText
        }
        try self.init(parsing: text)
    }

    init(parsing text: String) throws {
        var title: String?
        var size3D: Int?
        var size1D: Int?
        var domainMin = SIMD3<Float>(repeating: 0)
        var domainMax = SIMD3<Float>(repeating: 1)
        var values: [Float] = []
        values.reserveCapacity(text.utf8.count / 8)

        var lineNumber = 0
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            lineNumber += 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let first = fields.first else { continue }

            if let firstCharacter = first.first, firstCharacter.isLetter, Float(first) == nil {
                let keyword = first.uppercased()
                let arguments = fields.dropFirst()
                func number(_ index: Int) throws -> Float {
                    let field = arguments[arguments.index(arguments.startIndex, offsetBy: index)]
                    guard let value = Float(field), value.isFinite else {
                        throw CubeLUTError.badLine(number: lineNumber, reason: "“\(field)” is not a number.")
                    }
                    return value
                }
                func vector() throws -> SIMD3<Float> {
                    guard arguments.count == 3 else { throw CubeLUTError.badLine(number: lineNumber, reason: "\(keyword) needs three numbers.") }
                    return SIMD3(try number(0), try number(1), try number(2))
                }
                func range() throws -> (Float, Float) {
                    guard arguments.count == 2 else { throw CubeLUTError.badLine(number: lineNumber, reason: "\(keyword) needs two numbers.") }
                    return (try number(0), try number(1))
                }
                switch keyword {
                case "TITLE":
                    title = line.dropFirst(first.count).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                case "LUT_3D_SIZE", "LUT_1D_SIZE":
                    guard arguments.count == 1, let size = Int(arguments[arguments.startIndex]) else {
                        throw CubeLUTError.badLine(number: lineNumber, reason: "\(keyword) needs one whole number.")
                    }
                    if keyword == "LUT_3D_SIZE" { size3D = size } else { size1D = size }
                case "DOMAIN_MIN": domainMin = try vector()
                case "DOMAIN_MAX": domainMax = try vector()
                case "LUT_3D_INPUT_RANGE", "LUT_1D_INPUT_RANGE": // Resolve's spelling of a uniform domain.
                    let (low, high) = try range()
                    domainMin = SIMD3(repeating: low)
                    domainMax = SIMD3(repeating: high)
                default:
                    continue // Other keywords describe the file, not the table.
                }
                continue
            }

            guard fields.count == 3 else {
                throw CubeLUTError.badLine(number: lineNumber, reason: "a row needs three numbers; found \(fields.count).")
            }
            for field in fields {
                guard let value = Float(field), value.isFinite else {
                    throw CubeLUTError.badLine(number: lineNumber, reason: "“\(field)” is not a finite number (use a point for decimals).")
                }
                values.append(value)
            }
        }

        let kind: Kind
        switch (size3D, size1D) {
        case (nil, nil): throw CubeLUTError.missingSize
        case (.some, .some): throw CubeLUTError.bothSizes
        case (let size?, nil):
            guard Self.threeDSizes.contains(size) else {
                throw CubeLUTError.sizeOutOfRange(keyword: "LUT_3D_SIZE", size: size, range: Self.threeDSizes)
            }
            let expected = size * size * size
            guard values.count == expected * 3 else {
                throw CubeLUTError.wrongRowCount(keyword: "LUT_3D_SIZE", size: size, expected: expected, found: values.count / 3)
            }
            kind = .threeD(size: size)
        case (nil, let size?):
            guard Self.oneDSizes.contains(size) else {
                throw CubeLUTError.sizeOutOfRange(keyword: "LUT_1D_SIZE", size: size, range: Self.oneDSizes)
            }
            guard values.count == size * 3 else {
                throw CubeLUTError.wrongRowCount(keyword: "LUT_1D_SIZE", size: size, expected: size, found: values.count / 3)
            }
            kind = .oneD(size: size)
        }
        guard all(domainMin .< domainMax) else { throw CubeLUTError.invalidDomain }

        self.title = title
        self.kind = kind
        self.domainMin = domainMin
        self.domainMax = domainMax
        self.values = values
    }

    init(title: String? = nil, kind: Kind, domainMin: SIMD3<Float> = .zero, domainMax: SIMD3<Float> = .one, values: [Float]) {
        self.title = title
        self.kind = kind
        self.domainMin = domainMin
        self.domainMax = domainMax
        self.values = values
    }

    /// The table's output for lattice point (r, g, b) of a 3D LUT.
    func entry(r: Int, g: Int, b: Int) -> SIMD3<Float> {
        guard case .threeD(let size) = kind else { return .zero }
        let index = ((b * size + g) * size + r) * 3
        return SIMD3(values[index], values[index + 1], values[index + 2])
    }

    /// Reference evaluation in Double, tetrahedral for 3D and linear per channel for 1D, the same
    /// interpolation as the render kernels (and ffmpeg's `lut3d=interp=tetrahedral`).
    func evaluate(_ color: SIMD3<Double>) -> SIMD3<Double> {
        let low = SIMD3<Double>(domainMin), high = SIMD3<Double>(domainMax)
        let normalized = simd_clamp((color - low) / (high - low), .zero, .one)
        switch kind {
        case .oneD(let size):
            let x = normalized * Double(size - 1)
            func channel(_ c: Int) -> Double {
                let i = min(Int(x[c]), size - 2), f = x[c] - Double(i)
                return Double(values[i * 3 + c]) * (1 - f) + Double(values[(i + 1) * 3 + c]) * f
            }
            return SIMD3(channel(0), channel(1), channel(2))
        case .threeD(let size):
            let x = normalized * Double(size - 1)
            let base = SIMD3<Int>(min(Int(x.x), size - 2), min(Int(x.y), size - 2), min(Int(x.z), size - 2))
            let f = x - SIMD3<Double>(Double(base.x), Double(base.y), Double(base.z))
            func c(_ dr: Int, _ dg: Int, _ db: Int) -> SIMD3<Double> {
                SIMD3<Double>(entry(r: base.x + dr, g: base.y + dg, b: base.z + db))
            }
            let c000 = c(0, 0, 0), c111 = c(1, 1, 1)
            if f.x > f.y {
                if f.y > f.z { return c000 + (c(1, 0, 0) - c000) * f.x + (c(1, 1, 0) - c(1, 0, 0)) * f.y + (c111 - c(1, 1, 0)) * f.z }
                if f.x > f.z { return c000 + (c(1, 0, 0) - c000) * f.x + (c(1, 0, 1) - c(1, 0, 0)) * f.z + (c111 - c(1, 0, 1)) * f.y }
                return c000 + (c(0, 0, 1) - c000) * f.z + (c(1, 0, 1) - c(0, 0, 1)) * f.x + (c111 - c(1, 0, 1)) * f.y
            }
            if f.z > f.y { return c000 + (c(0, 0, 1) - c000) * f.z + (c(0, 1, 1) - c(0, 0, 1)) * f.y + (c111 - c(0, 1, 1)) * f.x }
            if f.z > f.x { return c000 + (c(0, 1, 0) - c000) * f.y + (c(0, 1, 1) - c(0, 1, 0)) * f.z + (c111 - c(0, 1, 1)) * f.x }
            return c000 + (c(0, 1, 0) - c000) * f.y + (c(1, 1, 0) - c(0, 1, 0)) * f.x + (c111 - c(1, 1, 0)) * f.z
        }
    }
}
