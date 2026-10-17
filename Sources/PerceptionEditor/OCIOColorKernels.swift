import Foundation
import Metal

/// A 1D lookup table that an OCIO-generated shader samples. OCIO's code computes texel centers
/// itself, so `nearest` reads exactly the stored value.
struct OCIOLookupTable: Sendable {
    enum Interpolation: Sendable { case nearest, linear }

    var name: String
    var width: Int
    /// 1 (red only) or 3 (RGB, uploaded as RGBA).
    var channels: Int
    var interpolation: Interpolation
    var values: [Float]
}

/// One OCIO transform as Metal source: a function `float4 functionName(<table, sampler>..., float4)`.
struct OCIOShaderTransform: Sendable {
    var name: String
    var functionName: String
    var tables: [OCIOLookupTable]
    var source: String
}

/// A camera log encoding that OpenColorIO turns into scene-linear Rec. 709.
enum OCIOInputTransform: String, Codable, Hashable, Sendable {
    /// Panasonic V-Log / V-Gamut, through OCIO's `PANASONIC_VLOG-VGAMUT_to_ACES2065-1`.
    case vLogVGamut
}

extension MetalShaderSources {
    static let ocioInputTransform = OCIOGeneratedShaders.vLogVGamutToLinearRec709
    static let ocioOutputTransform = OCIOGeneratedShaders.linearRec709ToRec1886ACES20
    /// Tables are bound after the input and output frames.
    static let ocioFirstTableIndex = 2

    /// OCIO's generated functions plus three kernels that run them per pixel: the input transform
    /// (code values to scene-linear Rec. 709, unclamped), the ACES 2.0 SDR output transform
    /// (scene-linear to Rec. 1886 Rec. 709 code values), and both in one pass for ungraded clips.
    static let ocio: String = {
        let input = ocioInputTransform, output = ocioOutputTransform
        func call(_ transform: OCIOShaderTransform, tableBase: Int, pixel: String) -> String {
            let tables = transform.tables.indices.map { "table\(tableBase + $0), \(samplerName(transform.tables[$0]))" }
            return "\(transform.functionName)(\((tables + [pixel]).joined(separator: ", ")))"
        }
        func tableParameters(_ transform: OCIOShaderTransform, tableBase: Int) -> String {
            transform.tables.indices.map {
                ",\n    texture1d<float> table\(tableBase + $0) [[texture(\(ocioFirstTableIndex + tableBase + $0))]]"
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
        // The input transform has no tables (the generator would have to change this if it did).
        precondition(input.tables.isEmpty, "OCIO input transforms with lookup tables are not wired up")
        return """
        #include <metal_stdlib>
        using namespace metal;

        constexpr sampler ocioNearest(filter::nearest, address::clamp_to_edge, coord::normalized);
        constexpr sampler ocioLinear(filter::linear, address::clamp_to_edge, coord::normalized);

        \(input.source)

        \(output.source)

        \(kernel("ocioInput", tables: "", body: "color = \(call(input, tableBase: 0, pixel: "color"));"))
        \(kernel("ocioOutput", tables: tableParameters(output, tableBase: 0), body: "color = \(call(output, tableBase: 0, pixel: "color"));"))
        \(kernel("ocioInputThenOutput", tables: tableParameters(output, tableBase: 0), body: """
        color = \(call(input, tableBase: 0, pixel: "color"));
            color = \(call(output, tableBase: 0, pixel: "color"));
        """))
        """
    }()

    private static func samplerName(_ table: OCIOLookupTable) -> String {
        table.interpolation == .linear ? "ocioLinear" : "ocioNearest"
    }
}

/// Runs OpenColorIO's V-Log and ACES 2.0 transforms on working frames (`rgba16Float`).
///
/// The shaders are generated offline by `scripts/ocio/generate-shaders.py`; OCIO itself is not
/// linked. They compile on first use, in a library separate from the other video kernels, so if
/// they fail the rest of the pipeline still works and V-Log clips show as recorded.
final class OCIOColorKernels: @unchecked Sendable {
    private static let loaded = Result { try OCIOColorKernels() }
    /// Compiles on first access (a few hundred milliseconds cold), so read it off the main actor.
    static var shared: OCIOColorKernels? { try? loaded.get() }
    static var loadError: (any Error)? {
        if case .failure(let error) = loaded { return error }
        return nil
    }

    let runtime: MetalPipelineCache
    private let outputTables: [MTLTexture]

    init(runtime: MetalPipelineCache? = MetalPipelineCache.shared) throws {
        guard let runtime else { throw VideoColorError.noMetalDevice }
        self.runtime = runtime
        outputTables = try MetalShaderSources.ocioOutputTransform.tables.map { try Self.makeTexture(for: $0, device: runtime.device) }
        for name in ["ocioInput", "ocioOutput", "ocioInputThenOutput"] { _ = try runtime.pipeline(named: name, in: .ocio) }
    }

    /// Camera log code values to scene-linear Rec. 709. Not clamped: highlights go well above 1.
    func toSceneLinear(_ input: MTLTexture, from transform: OCIOInputTransform, into output: MTLTexture, commandBuffer: MTLCommandBuffer) throws {
        try run("ocioInput", input, into: output, tables: [], commandBuffer: commandBuffer)
    }

    /// Scene-linear Rec. 709 to Rec. 709 display code values through ACES 2.0 SDR 100 nits.
    func toDisplay(_ input: MTLTexture, into output: MTLTexture, commandBuffer: MTLCommandBuffer) throws {
        try run("ocioOutput", input, into: output, tables: outputTables, commandBuffer: commandBuffer)
    }

    /// Both transforms in one pass, for a clip with nothing to grade in between.
    func toDisplay(_ input: MTLTexture, from transform: OCIOInputTransform, into output: MTLTexture, commandBuffer: MTLCommandBuffer) throws {
        try run("ocioInputThenOutput", input, into: output, tables: outputTables, commandBuffer: commandBuffer)
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

    /// Tables stay 32-bit float: half float would cost the ACES tables precision for no saving
    /// worth having (a few kilobytes).
    private static func makeTexture(for table: OCIOLookupTable, device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type1D
        descriptor.width = table.width
        descriptor.pixelFormat = table.channels == 1 ? .r32Float : .rgba32Float
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard table.values.count == table.width * table.channels, table.channels == 1 || table.channels == 3,
              let texture = device.makeTexture(descriptor: descriptor) else {
            throw VideoColorError.shaderCompilationFailed("OCIO table \(table.name) is malformed")
        }
        let texels = table.channels == 1
            ? table.values
            : (0 ..< table.width).flatMap { [table.values[$0 * 3], table.values[$0 * 3 + 1], table.values[$0 * 3 + 2], 1] }
        texels.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake1D(0, table.width), mipmapLevel: 0, withBytes: bytes.baseAddress!, bytesPerRow: bytes.count)
        }
        return texture
    }
}
