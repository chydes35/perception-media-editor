import CryptoKit
import Foundation
import Metal
import Testing
@testable import PerceptionEditor

/// The generated OCIO shaders against OCIO's own CPU processor, an independent V-Log formula, and
/// the generator script that wrote them. The golden data is `Tests/Fixtures/ocio-golden.json`,
/// written by `scripts/ocio/generate-shaders.py`; its inputs are exact in half float, so the GPU
/// reads exactly what the CPU processed.
struct OCIOGeneratedSourceTests {
    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func generatedFileMatchesTheGeneratorScript() throws {
        let script = try Data(contentsOf: Self.repositoryRoot.appending(path: "scripts/ocio/generate-shaders.py"))
        let hash = SHA256.hash(data: script).map { String(format: "%02x", $0) }.joined()
        #expect(hash == OCIOGeneratedShaders.scriptSHA256,
                "scripts/ocio/generate-shaders.py changed; rerun it so OCIOGeneratedShaders.swift and the golden data match")
    }

    @Test func goldenDataComesFromTheSameOCIOAndConfig() throws {
        let golden = try OCIOGolden.load()
        #expect(golden.ocioVersion == OCIOGeneratedShaders.ocioVersion)
        #expect(golden.config == OCIOGeneratedShaders.configName)
        #expect(OCIOGeneratedShaders.configName.contains("aces-v2.0"))
    }

    @Test func outputTransformTablesAreComplete() {
        let tables = OCIOGeneratedShaders.linearRec709ToRec1886ACES20.tables
        #expect(tables.map(\.channels) == [1, 3])
        for table in tables { #expect(table.values.count == table.width * table.channels, "\(table.name)") }
        #expect(OCIOGeneratedShaders.vLogVGamutToLinearRec709.tables.isEmpty)
    }

    /// OCIO's camera-log curve and V-Gamut primaries, written out in Double from Panasonic's V-Log
    /// definition, agree with OCIO's CPU processor.
    @Test func vLogOracleAgreesWithOCIO() throws {
        let golden = try OCIOGolden.load().transform(MetalShaderSources.ocioInputTransform.name)
        var worst = 0.0
        for (input, expected) in zip(golden.inputs, golden.outputs) {
            let actual = VLogOracle.linearRec709(input.map(Double.init))
            for channel in 0 ..< 3 {
                let error = OCIOGolden.error(Double(expected[channel]), actual[channel])
                worst = max(worst, error)
            }
        }
        #expect(worst <= 1e-4, "worst error \(worst)")
    }

    @Test func eighteenPercentGreyIsCode433() {
        let linear = VLogOracle.linearRec709([433.0 / 1023, 433.0 / 1023, 433.0 / 1023])
        for value in linear { #expect(abs(value - 0.18) < 0.001) }
    }
}

@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct OCIOShaderTests {
    @Test func inputTransformMatchesOCIO() throws {
        let kernels = try #require(OCIOColorKernels.shared, "\(String(describing: OCIOColorKernels.loadError))")
        let golden = try OCIOGolden.load().transform(MetalShaderSources.ocioInputTransform.name)
        let output = try Self.run(golden.inputs, kernels: kernels) { input, output, commandBuffer in
            try kernels.toSceneLinear(input, from: .vLogVGamut, into: output, commandBuffer: commandBuffer)
        }
        Self.expectAgreement(output, golden.outputs)
    }

    @Test func outputTransformMatchesOCIO() throws {
        let kernels = try #require(OCIOColorKernels.shared, "\(String(describing: OCIOColorKernels.loadError))")
        let golden = try OCIOGolden.load().transform(MetalShaderSources.ocioOutputTransform.name)
        let output = try Self.run(golden.inputs, kernels: kernels) { input, output, commandBuffer in
            try kernels.toDisplay(input, into: output, commandBuffer: commandBuffer)
        }
        Self.expectAgreement(output, golden.outputs)
    }

    /// The one-pass kernel against OCIO's CPU running both transforms. (The two passes differ from
    /// it by their half-float intermediate, which the gamut compression can magnify to 3e-3.)
    @Test func fusedKernelMatchesBothTransforms() throws {
        let kernels = try #require(OCIOColorKernels.shared)
        let golden = try OCIOGolden.load().transform("vlog_vgamut_to_rec1886_aces20")
        let output = try Self.run(golden.inputs, kernels: kernels) { input, output, commandBuffer in
            try kernels.toDisplay(input, from: .vLogVGamut, into: output, commandBuffer: commandBuffer)
        }
        Self.expectAgreement(output, golden.outputs)
    }

    @Test func eighteenPercentGreyOnTheGPU() throws {
        let kernels = try #require(OCIOColorKernels.shared)
        let code = Float(433.0 / 1023)
        let output = try Self.run([[code, code, code]], kernels: kernels) { input, output, commandBuffer in
            try kernels.toSceneLinear(input, from: .vLogVGamut, into: output, commandBuffer: commandBuffer)
        }
        for value in output[0] { #expect(abs(value - 0.18) < 0.002, "\(output[0])") }
    }

    /// Within 1e-3 absolute in the 0…1 range and 0.2% relative above it (half-float output).
    static func expectAgreement(_ actual: [[Float]], _ expected: [[Float]], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(actual.count == expected.count, sourceLocation: sourceLocation)
        // Each error as a fraction of its limit, so one number covers both ranges.
        var worst = 0.0, worstIndex = 0
        for (index, (a, e)) in zip(actual, expected).enumerated() {
            for channel in 0 ..< 3 {
                let limit = abs(e[channel]) > 1 ? 2e-3 : 1e-3
                let share = OCIOGolden.error(Double(e[channel]), Double(a[channel])) / limit
                if share > worst { (worst, worstIndex) = (share, index) }
            }
        }
        #expect(worst <= 1, "worst error \(worst) of its limit at \(worstIndex): got \(actual[worstIndex]), expected \(expected[worstIndex])",
                sourceLocation: sourceLocation)
    }

    /// Writes `pixels` into a square `rgba16Float` frame, runs `body`, and reads the result back.
    static func run(
        _ pixels: [[Float]], kernels: OCIOColorKernels,
        _ body: (MTLTexture, MTLTexture, MTLCommandBuffer) throws -> Void
    ) throws -> [[Float]] {
        let side = Int(Double(pixels.count).squareRoot().rounded(.up))
        let device = kernels.runtime.device
        func texture() throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: side, height: side, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .shared
            return try #require(device.makeTexture(descriptor: descriptor))
        }
        let input = try texture(), output = try texture()
        var halves = [Float16](repeating: 0, count: side * side * 4)
        for (index, pixel) in pixels.enumerated() {
            for channel in 0 ..< 3 { halves[index * 4 + channel] = Float16(pixel[channel]) }
            halves[index * 4 + 3] = 1
        }
        input.replace(region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0, withBytes: halves, bytesPerRow: side * 8)
        let commandBuffer = try #require(kernels.runtime.queue.makeCommandBuffer())
        try body(input, output, commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed, "\(String(describing: commandBuffer.error))")
        output.getBytes(&halves, bytesPerRow: side * 8, from: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0)
        return pixels.indices.map { index in (0 ..< 3).map { Float(halves[index * 4 + $0]) } }
    }
}

struct OCIOGolden: Decodable {
    struct Transform: Decodable {
        var inputs: [[Float]]
        var outputs: [[Float]]
    }

    var ocioVersion: String
    var config: String
    var transforms: [String: Transform]

    nonisolated(unsafe) private static var cached: OCIOGolden?
    private static let lock = NSLock()

    static func load() throws -> OCIOGolden {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let url = OCIOGeneratedSourceTests.repositoryRoot.appending(path: "Tests/Fixtures/ocio-golden.json")
        let golden = try JSONDecoder().decode(OCIOGolden.self, from: Data(contentsOf: url))
        cached = golden
        return golden
    }

    func transform(_ name: String) throws -> Transform {
        try #require(transforms[name], "No golden data for \(name)")
    }

    /// Absolute error up to magnitude 1, relative above it.
    static func error(_ expected: Double, _ actual: Double) -> Double {
        abs(expected) > 1 ? abs(actual - expected) / abs(expected) : abs(actual - expected)
    }
}

/// Panasonic V-Log to linear, and V-Gamut to Rec. 709 primaries, in Double. Written from the
/// published definitions, not from OCIO, so the comparison can catch a wrong generated transform.
enum VLogOracle {
    static let (b, c, d) = (0.00873, 0.241514, 0.598206)
    /// Below code 0.181 (linear 0.01) V-Log is the straight line 5.6·x + 0.125.
    static let cut = 0.181

    static func linear(_ code: Double) -> Double {
        code < cut ? (code - 0.125) / 5.6 : pow(10, (code - d) / c) - b
    }

    static func linearRec709(_ codes: [Double]) -> [Double] {
        let lin = codes.map(linear)
        return (0 ..< 3).map { row in (0 ..< 3).reduce(0) { $0 + vGamutToRec709[row][$1] * lin[$1] } }
    }

    /// Both are D65, so this is RGB→XYZ for V-Gamut followed by XYZ→RGB for Rec. 709.
    static let vGamutToRec709: [[Double]] = {
        let vGamut = npm(red: (0.730, 0.280), green: (0.165, 0.840), blue: (0.100, -0.030))
        let rec709 = npm(red: (0.640, 0.330), green: (0.300, 0.600), blue: (0.150, 0.060))
        return multiply(invert(rec709), vGamut)
    }()

    static let d65 = (0.3127, 0.3290)

    /// The normalized primary matrix (RGB to XYZ) for chromaticities with a D65 white.
    static func npm(red: (Double, Double), green: (Double, Double), blue: (Double, Double)) -> [[Double]] {
        func xyz(_ p: (Double, Double)) -> [Double] { [p.0 / p.1, 1, (1 - p.0 - p.1) / p.1] }
        let primaries = [xyz(red), xyz(green), xyz(blue)]
        let columns = (0 ..< 3).map { row in (0 ..< 3).map { primaries[$0][row] } }
        let white = xyz(d65)
        let scale = (0 ..< 3).map { row in (0 ..< 3).reduce(0) { $0 + invert(columns)[row][$1] * white[$1] } }
        return (0 ..< 3).map { row in (0 ..< 3).map { columns[row][$0] * scale[$0] } }
    }

    static func multiply(_ a: [[Double]], _ b: [[Double]]) -> [[Double]] {
        (0 ..< 3).map { row in (0 ..< 3).map { column in (0 ..< 3).reduce(0) { $0 + a[row][$1] * b[$1][column] } } }
    }

    static func invert(_ m: [[Double]]) -> [[Double]] {
        let det = m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
            - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
            + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
        let cofactors: [[Double]] = [
            [m[1][1] * m[2][2] - m[1][2] * m[2][1], m[0][2] * m[2][1] - m[0][1] * m[2][2], m[0][1] * m[1][2] - m[0][2] * m[1][1]],
            [m[1][2] * m[2][0] - m[1][0] * m[2][2], m[0][0] * m[2][2] - m[0][2] * m[2][0], m[0][2] * m[1][0] - m[0][0] * m[1][2]],
            [m[1][0] * m[2][1] - m[1][1] * m[2][0], m[0][1] * m[2][0] - m[0][0] * m[2][1], m[0][0] * m[1][1] - m[0][1] * m[1][0]]
        ]
        return cofactors.map { $0.map { $0 / det } }
    }
}
