import Foundation
import Metal

/// A lookup table that an OCIO-generated shader samples. OCIO's code computes texel coordinates
/// itself: `nearest` tables are read at texel centres, and `linear` ones (such as Apple Log's
/// half-float-domain curve, folded into a 2D texture) rely on the sampler's filtering.
struct OCIOLookupTable: Sendable {
    enum Interpolation: Sendable { case nearest, linear }

    var name: String
    var width: Int
    var height: Int
    /// A 2D texture (`texture2d<float>` in OCIO's function signature); otherwise 1D.
    var twoD: Bool
    /// 1 (red only) or 3 (RGB, uploaded as RGBA).
    var channels: Int
    var interpolation: Interpolation
    /// Little-endian float32 values, row by row, as the generator wrote them. Decoded on first use;
    /// array literals this size (Apple Log's is 69 632 floats) would slow the compiler to a crawl.
    var float32Base64: String

    var values: [Float] {
        guard let data = Data(base64Encoded: float32Base64) else { return [] }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

/// One OCIO transform as Metal source: a function `float4 functionName(<table, sampler>..., float4)`.
struct OCIOShaderTransform: Sendable {
    var name: String
    var functionName: String
    var tables: [OCIOLookupTable]
    var source: String
}

/// A camera log encoding that OpenColorIO turns into scene-linear Rec. 709.
enum OCIOInputTransform: String, Codable, Hashable, Sendable, CaseIterable {
    /// Panasonic V-Log / V-Gamut, through OCIO's `PANASONIC_VLOG-VGAMUT_to_ACES2065-1`.
    case vLogVGamut
    /// iPhone Apple Log / BT.2020, through OCIO's `APPLE_LOG_to_ACES2065-1` (Apple's white paper curve).
    case appleLog
}

extension MetalShaderSources {
    static func ocioInputTransform(_ input: OCIOInputTransform) -> OCIOShaderTransform {
        switch input {
        case .vLogVGamut: OCIOGeneratedShaders.vLogVGamutToLinearRec709
        case .appleLog: OCIOGeneratedShaders.appleLogRec2020ToLinearRec709
        }
    }

    static let ocioOutputTransform = OCIOGeneratedShaders.linearRec709ToRec1886ACES20
    /// Tables are bound after the input and output frames: the input transform's first, then the output's.
    static let ocioFirstTableIndex = 2

    static func ocioInputKernel(_ input: OCIOInputTransform) -> String { "ocioInput_\(input.rawValue)" }
    static func ocioInputThenOutputKernel(_ input: OCIOInputTransform) -> String { "ocioInputThenOutput_\(input.rawValue)" }
    static let ocioOutputKernel = "ocioOutput"

    /// OCIO's generated functions plus kernels that run them per pixel: each camera's input transform
    /// (code values to scene-linear Rec. 709, unclamped), the ACES 2.0 SDR output transform
    /// (scene-linear to Rec. 1886 Rec. 709 code values), and each camera's input and output in one
    /// pass for ungraded clips.
    static let ocio: String = {
        let output = ocioOutputTransform
        func call(_ transform: OCIOShaderTransform, tableBase: Int, pixel: String) -> String {
            let tables = transform.tables.indices.map { "table\(tableBase + $0), \(samplerName(transform.tables[$0]))" }
            return "\(transform.functionName)(\((tables + [pixel]).joined(separator: ", ")))"
        }
        func tableParameters(_ transform: OCIOShaderTransform, tableBase: Int) -> String {
            transform.tables.indices.map {
                let type = transform.tables[$0].twoD ? "texture2d<float>" : "texture1d<float>"
                return ",\n    \(type) table\(tableBase + $0) [[texture(\(ocioFirstTableIndex + tableBase + $0))]]"
            }.joined()
        }
        func kernel(_ name: String, tables: String, body: String) -> String {
            """
            kernel void \(name)(
                texture2d<float, access::read> input [[texture(0)]],
                texture2d<float, access::write> output [[texture(1)]]\(tables),
                uint2 gid [[thread_position_in_grid]])
            {
                if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
                float4 pixel = input.read(gid);
                float4 color = float4(pixel.rgb, 1.0);
                \(body)
                output.write(float4(color.rgb, pixel.a), gid);
            }

            """
        }
        var parts = [
            """
            #include <metal_stdlib>
            using namespace metal;

            constexpr sampler ocioNearest(filter::nearest, address::clamp_to_edge, coord::normalized);
            constexpr sampler ocioLinear(filter::linear, address::clamp_to_edge, coord::normalized);
            """,
            output.source,
            kernel(ocioOutputKernel, tables: tableParameters(output, tableBase: 0), body: "color = \(call(output, tableBase: 0, pixel: "color"));")
        ]
        for camera in OCIOInputTransform.allCases {
            let input = ocioInputTransform(camera)
            let count = input.tables.count
            parts.append(input.source)
            parts.append(kernel(ocioInputKernel(camera), tables: tableParameters(input, tableBase: 0),
                                body: "color = \(call(input, tableBase: 0, pixel: "color"));"))
            parts.append(kernel(ocioInputThenOutputKernel(camera),
                                tables: tableParameters(input, tableBase: 0) + tableParameters(output, tableBase: count), body: """
            color = \(call(input, tableBase: 0, pixel: "color"));
                color = \(call(output, tableBase: count, pixel: "color"));
            """))
        }
        return parts.joined(separator: "\n\n")
    }()

    private static func samplerName(_ table: OCIOLookupTable) -> String {
        table.interpolation == .linear ? "ocioLinear" : "ocioNearest"
    }
}

/// Runs OpenColorIO's camera input transforms (V-Log, Apple Log) and ACES 2.0 output transform on
/// working frames (`rgba16Float`).
///
/// The shaders are generated offline by `scripts/ocio/generate-shaders.py`; OCIO itself is not
/// linked. They compile on first use, in a library separate from the other video kernels, so if
/// they fail the rest of the pipeline still works and log clips show as recorded.
final class OCIOColorKernels: @unchecked Sendable {
    private static let loaded = Result { try OCIOColorKernels() }
    /// Compiles on first access (a few hundred milliseconds cold), so read it off the main actor.
    static var shared: OCIOColorKernels? { try? loaded.get() }
    static var loadError: (any Error)? {
        if case .failure(let error) = loaded { return error }
        return nil
    }

    let runtime: MetalPipelineCache
    private let inputTables: [OCIOInputTransform: [MTLTexture]]
    private let outputTables: [MTLTexture]

    init(runtime: MetalPipelineCache? = MetalPipelineCache.shared) throws {
        guard let runtime else { throw VideoColorError.noMetalDevice }
        self.runtime = runtime
        let device = runtime.device
        outputTables = try MetalShaderSources.ocioOutputTransform.tables.map { try Self.makeTexture(for: $0, device: device) }
        var inputs: [OCIOInputTransform: [MTLTexture]] = [:]
        for camera in OCIOInputTransform.allCases {
            inputs[camera] = try MetalShaderSources.ocioInputTransform(camera).tables.map { try Self.makeTexture(for: $0, device: device) }
        }
        inputTables = inputs
        var names = [MetalShaderSources.ocioOutputKernel]
        for camera in OCIOInputTransform.allCases {
            names += [MetalShaderSources.ocioInputKernel(camera), MetalShaderSources.ocioInputThenOutputKernel(camera)]
        }
        for name in names { _ = try runtime.pipeline(named: name, in: .ocio) }
    }

    /// Camera log code values to scene-linear Rec. 709. Not clamped: highlights go well above 1.
    func toSceneLinear(_ input: MTLTexture, from transform: OCIOInputTransform, into output: MTLTexture, commandBuffer: MTLCommandBuffer) throws {
        try run(MetalShaderSources.ocioInputKernel(transform), input, into: output, tables: inputTables[transform] ?? [], commandBuffer: commandBuffer)
    }

    /// Scene-linear Rec. 709 to Rec. 709 display code values through ACES 2.0 SDR 100 nits.
    func toDisplay(_ input: MTLTexture, into output: MTLTexture, commandBuffer: MTLCommandBuffer) throws {
        try run(MetalShaderSources.ocioOutputKernel, input, into: output, tables: outputTables, commandBuffer: commandBuffer)
    }

    /// Both transforms in one pass, for a clip with nothing to grade in between.
    func toDisplay(_ input: MTLTexture, from transform: OCIOInputTransform, into output: MTLTexture, commandBuffer: MTLCommandBuffer) throws {
        try run(MetalShaderSources.ocioInputThenOutputKernel(transform), input, into: output,
                tables: (inputTables[transform] ?? []) + outputTables, commandBuffer: commandBuffer)
    }

    private func run(_ name: String, _ input: MTLTexture, into output: MTLTexture, tables: [MTLTexture], commandBuffer: MTLCommandBuffer) throws {
        guard input.width == output.width, input.height == output.height else {
            throw VideoColorError.sizeMismatch("\(name) needs equal sizes, got \(input.width)×\(input.height) and \(output.width)×\(output.height)")
        }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw VideoColorError.noMetalDevice }
        encoder.setComputePipelineState(try runtime.pipeline(named: name, in: .ocio))
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        for (offset, table) in tables.enumerated() { encoder.setTexture(table, index: MetalShaderSources.ocioFirstTableIndex + offset) }
        encoder.dispatchThreads(
            MTLSize(width: output.width, height: output.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)
        )
        encoder.endEncoding()
    }

    /// Tables stay 32-bit float: half float would cost the curves precision for no saving worth
    /// having (Apple Log's table is 272 KB). Linear filtering of 32-bit float textures, which the
    /// Apple Log table needs, is checked rather than assumed.
    private static func makeTexture(for table: OCIOLookupTable, device: MTLDevice) throws -> MTLTexture {
        if table.interpolation == .linear, !device.supports32BitFloatFiltering {
            throw VideoColorError.shaderCompilationFailed("this GPU cannot filter 32-bit float textures (OCIO table \(table.name))")
        }
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = table.twoD ? .type2D : .type1D
        descriptor.width = table.width
        descriptor.height = table.twoD ? table.height : 1
        descriptor.pixelFormat = table.channels == 1 ? .r32Float : .rgba32Float
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        let values = table.values
        let rows = table.twoD ? table.height : 1
        guard values.count == table.width * rows * table.channels, table.channels == 1 || table.channels == 3,
              let texture = device.makeTexture(descriptor: descriptor) else {
            throw VideoColorError.shaderCompilationFailed("OCIO table \(table.name) is malformed")
        }
        let texels = table.channels == 1
            ? values
            : (0 ..< table.width * rows).flatMap { [values[$0 * 3], values[$0 * 3 + 1], values[$0 * 3 + 2], Float(1)] }
        let texelBytes = (table.channels == 1 ? 1 : 4) * MemoryLayout<Float>.size
        texels.withUnsafeBytes { bytes in
            let region = table.twoD ? MTLRegionMake2D(0, 0, table.width, rows) : MTLRegionMake1D(0, table.width)
            texture.replace(region: region, mipmapLevel: 0, withBytes: bytes.baseAddress!, bytesPerRow: table.width * texelBytes)
        }
        return texture
    }
}
