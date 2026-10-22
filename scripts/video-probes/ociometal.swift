// Compiles OCIO-generated MSL at runtime (no `metal` compiler on CLT) and compares GPU vs OCIO CPU golden values.
import Foundation
import Metal

let dir = CommandLine.arguments[1]
let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!

func load(_ name: String) -> [Float] {
    let d = try! Data(contentsOf: URL(fileURLWithPath: "\(dir)/\(name)"))
    return d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}

func run(_ name: String, textures: [(String, Int)]) throws {
    let body = try String(contentsOfFile: "\(dir)/\(name).metal", encoding: .utf8)
    let texParams = textures.enumerated().map { "texture1d<float> t\($0.offset) [[texture(\($0.offset))]]" }.joined(separator: ", ")
    let texArgs = textures.indices.map { "t\($0), s" }.joined(separator: ", ")
    let source = """
    #include <metal_stdlib>
    using namespace metal;
    \(body)
    kernel void run(device const float* inp [[buffer(0)]], device float* outp [[buffer(1)]]\(textures.isEmpty ? "" : ", " + texParams), uint i [[thread_position_in_grid]]) {
        constexpr sampler s(filter::nearest, address::clamp_to_edge);
        float4 p = float4(inp[i*6], inp[i*6+1], inp[i*6+2], 1.0);
        float4 r = ocio_\(name)(\(textures.isEmpty ? "" : texArgs + ", ")p);
        outp[i*3] = r.r; outp[i*3+1] = r.g; outp[i*3+2] = r.b;
    }
    """
    let t0 = Date()
    let options = MTLCompileOptions()
    options.languageVersion = .version2_4
    let lib = try device.makeLibrary(source: source, options: options)
    let pipeline = try device.makeComputePipelineState(function: lib.makeFunction(name: "run")!)
    let compileMs = Date().timeIntervalSince(t0) * 1000
    let golden = load("\(name).golden.f32")
    let n = golden.count / 6
    let inBuf = device.makeBuffer(bytes: golden, length: golden.count * 4)!
    let outBuf = device.makeBuffer(length: n * 3 * 4)!
    var texObjects: [MTLTexture] = []
    for (texName, channels) in textures {
        let v = load("\(texName).f32")
        let width = v.count / channels
        let desc = MTLTextureDescriptor()
        desc.textureType = .type1D; desc.width = width
        desc.pixelFormat = channels == 1 ? .r32Float : .rgba32Float
        let tex = device.makeTexture(descriptor: desc)!
        var data = v
        if channels == 3 { data = (0 ..< width).flatMap { [v[$0 * 3], v[$0 * 3 + 1], v[$0 * 3 + 2], 1] } }
        tex.replace(region: MTLRegionMake1D(0, width), mipmapLevel: 0, withBytes: data, bytesPerRow: data.count * 4)
        texObjects.append(tex)
    }
    let cb = queue.makeCommandBuffer()!, enc = cb.makeComputeCommandEncoder()!
    enc.setComputePipelineState(pipeline)
    enc.setBuffer(inBuf, offset: 0, index: 0); enc.setBuffer(outBuf, offset: 0, index: 1)
    for (i, t) in texObjects.enumerated() { enc.setTexture(t, index: i) }
    enc.dispatchThreads(MTLSize(width: n, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
    enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    let out = outBuf.contents().bindMemory(to: Float.self, capacity: n * 3)
    var maxAbs: Float = 0, maxRel: Float = 0
    for i in 0 ..< n { for c in 0 ..< 3 {
        let g = golden[i * 6 + 3 + c], o = out[i * 3 + c]
        maxAbs = max(maxAbs, abs(g - o)); if abs(g) > 1 { maxRel = max(maxRel, abs(g - o) / abs(g)) }
    } }
    print(String(format: "%@: compiled in %.0f ms, %d samples, max abs err %.2e, max rel err (|v|>1) %.2e, status %d", name, compileMs, n, maxAbs, maxRel, cb.status.rawValue))
}

try run("vlog_to_linrec709", textures: [])
try run("builtin_vlog_to_ap0", textures: [])
try run("linrec709_to_rec1886_aces20", textures: [("linrec709_to_rec1886_aces20_reach_m_table_0", 1), ("linrec709_to_rec1886_aces20_gamut_cusp_table_0", 3)])
