import CoreGraphics
import Foundation
import Metal

enum WaveformMode: String, CaseIterable, Identifiable, Sendable {
    case luma = "Luma"
    case rgbParade = "RGB Parade"

    var id: String { rawValue }
}

/// One frame's scopes: the raw counts (for tests and measurements) and the images to show.
struct ScopeAnalysis: @unchecked Sendable {
    var waveform: [UInt32]
    var vectorscope: [UInt32]
    var columns: Int
    var bins: Int
    var size: Int
    var waveformImage: CGImage
    var vectorscopeImage: CGImage
    /// 256 bins per channel of the frame's code values, each channel scaled so its tallest bin is 1 (like the photo histogram).
    var histogram: HistogramData
    var gpuMilliseconds: Double
}

private struct ScopeParameters {
    var kr: Float
    var kb: Float
    var columns: UInt32
    var bins: UInt32
    var mode: UInt32
}

private struct ScopeRenderParameters {
    var columns: UInt32
    var bins: UInt32
    var mode: UInt32
    var gain: Float
}

/// Waveform and vectorscope on the GPU, from a small `rgba16Float` frame (the scope tap's
/// capture, in display-encoded R'G'B'). It has its own command queue, so scope work never waits
/// behind playback frames. Calls are synchronous; run them off the main actor.
final class ScopeRenderer: @unchecked Sendable {
    static let columns = 512
    static let bins = 1024
    static let size = 512
    static let displayHeight = 512

    private let runtime: MetalPipelineCache
    private let queue: MTLCommandQueue
    private let waveformBuffer: MTLBuffer
    private let vectorscopeBuffer: MTLBuffer
    private let histogramBuffer: MTLBuffer
    private let waveformTexture: MTLTexture
    private let vectorscopeTexture: MTLTexture
    private let lock = NSLock()

    init(runtime: MetalPipelineCache? = MetalPipelineCache.shared) throws {
        guard let runtime, let queue = runtime.device.makeCommandQueue(),
              let waveform = runtime.device.makeBuffer(length: Self.columns * Self.bins * 4, options: .storageModeShared),
              let vectorscope = runtime.device.makeBuffer(length: Self.size * Self.size * 4, options: .storageModeShared),
              let histogram = runtime.device.makeBuffer(length: 3 * 256 * 4, options: .storageModeShared)
        else { throw VideoColorError.noMetalDevice }
        func image(_ width: Int, _ height: Int) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.usage = [.shaderWrite]
            descriptor.storageMode = .shared
            guard let texture = runtime.device.makeTexture(descriptor: descriptor) else { throw VideoColorError.noMetalDevice }
            return texture
        }
        self.runtime = runtime
        self.queue = queue
        waveformBuffer = waveform
        vectorscopeBuffer = vectorscope
        histogramBuffer = histogram
        waveformTexture = try image(Self.columns, Self.displayHeight)
        vectorscopeTexture = try image(Self.size, Self.size)
        try runtime.prepare()
    }

    /// The vectorscope bin of a Cb/Cr pair (v = 0 at the top, where Cr is largest).
    static func vectorscopeBin(cb: Float, cr: Float, size: Int) -> (u: Int, v: Int) {
        let top = Float(size - 1)
        return (Int(min(top, max(0, ((cb + 0.5) * top).rounded()))), Int(min(top, max(0, ((0.5 - cr) * top).rounded()))))
    }

    /// The waveform image row a code value falls on.
    static func waveformRow(forCode code: Int, height: Int) -> Int {
        height - 1 - code / max(1, bins / height)
    }

    func analyze(_ frame: MTLTexture, mode: WaveformMode, matrix: YCbCrMatrix = .rec709) throws -> ScopeAnalysis {
        lock.lock()
        defer { lock.unlock() }
        guard let commandBuffer = queue.makeCommandBuffer(), let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw VideoColorError.noMetalDevice
        }
        blit.fill(buffer: waveformBuffer, range: 0 ..< waveformBuffer.length, value: 0)
        blit.fill(buffer: vectorscopeBuffer, range: 0 ..< vectorscopeBuffer.length, value: 0)
        blit.fill(buffer: histogramBuffer, range: 0 ..< histogramBuffer.length, value: 0)
        blit.endEncoding()

        let coefficients = matrix.coefficients
        var waveformParameters = ScopeParameters(kr: Float(coefficients.kr), kb: Float(coefficients.kb), columns: UInt32(Self.columns),
                                                 bins: UInt32(Self.bins), mode: mode == .luma ? 0 : 1)
        var vectorscopeParameters = waveformParameters
        vectorscopeParameters.columns = UInt32(Self.size)
        guard let accumulate = commandBuffer.makeComputeCommandEncoder() else { throw VideoColorError.noMetalDevice }
        accumulate.setTexture(frame, index: 0)
        accumulate.setComputePipelineState(try runtime.pipeline(named: "waveformAccumulate"))
        accumulate.setBuffer(waveformBuffer, offset: 0, index: 0)
        accumulate.setBytes(&waveformParameters, length: MemoryLayout<ScopeParameters>.stride, index: 1)
        dispatch(accumulate, frame.width, frame.height)
        accumulate.setComputePipelineState(try runtime.pipeline(named: "vectorscopeAccumulate"))
        accumulate.setBuffer(vectorscopeBuffer, offset: 0, index: 0)
        accumulate.setBytes(&vectorscopeParameters, length: MemoryLayout<ScopeParameters>.stride, index: 1)
        dispatch(accumulate, frame.width, frame.height)
        accumulate.setComputePipelineState(try runtime.pipeline(named: "histogramAccumulate"))
        accumulate.setBuffer(histogramBuffer, offset: 0, index: 0)
        dispatch(accumulate, frame.width, frame.height)

        // A column of the frame spreads its pixels over its bins; show a quarter of a column at full brightness.
        var waveformRender = ScopeRenderParameters(columns: UInt32(Self.columns), bins: UInt32(Self.bins), mode: mode == .luma ? 0 : 1,
                                                   gain: max(1, Float(frame.height) / 4))
        var vectorscopeRender = ScopeRenderParameters(columns: UInt32(Self.size), bins: 0, mode: 0,
                                                      gain: max(1, Float(frame.width * frame.height) / 2000))
        var targets = Self.barTargets(coefficients: coefficients)
        var skin = Self.skinToneDirection
        accumulate.setComputePipelineState(try runtime.pipeline(named: "renderWaveform"))
        accumulate.setBuffer(waveformBuffer, offset: 0, index: 0)
        accumulate.setBytes(&waveformRender, length: MemoryLayout<ScopeRenderParameters>.stride, index: 1)
        accumulate.setTexture(waveformTexture, index: 0)
        dispatch(accumulate, waveformTexture.width, waveformTexture.height)
        accumulate.setComputePipelineState(try runtime.pipeline(named: "renderVectorscope"))
        accumulate.setBuffer(vectorscopeBuffer, offset: 0, index: 0)
        accumulate.setBytes(&vectorscopeRender, length: MemoryLayout<ScopeRenderParameters>.stride, index: 1)
        accumulate.setBytes(&targets, length: MemoryLayout<SIMD2<Float>>.stride * targets.count, index: 2)
        accumulate.setBytes(&skin, length: MemoryLayout<SIMD2<Float>>.stride, index: 3)
        accumulate.setTexture(vectorscopeTexture, index: 0)
        dispatch(accumulate, vectorscopeTexture.width, vectorscopeTexture.height)
        accumulate.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { throw commandBuffer.error ?? VideoColorError.noMetalDevice }

        let waveform = Array(UnsafeBufferPointer(start: waveformBuffer.contents().bindMemory(to: UInt32.self, capacity: Self.columns * Self.bins),
                                                 count: Self.columns * Self.bins))
        let vectorscope = Array(UnsafeBufferPointer(start: vectorscopeBuffer.contents().bindMemory(to: UInt32.self, capacity: Self.size * Self.size),
                                                    count: Self.size * Self.size))
        let counts = Array(UnsafeBufferPointer(start: histogramBuffer.contents().bindMemory(to: UInt32.self, capacity: 3 * 256), count: 3 * 256))
        func channel(_ index: Int) -> [Double] {
            let bins = counts[index * 256 ..< (index + 1) * 256].map(Double.init)
            let peak = bins.max() ?? 0
            return peak > 0 ? bins.map { $0 / peak } : bins
        }
        return ScopeAnalysis(
            waveform: waveform, vectorscope: vectorscope, columns: Self.columns, bins: Self.bins, size: Self.size,
            waveformImage: try Self.image(waveformTexture), vectorscopeImage: try Self.image(vectorscopeTexture),
            histogram: HistogramData(red: channel(0), green: channel(1), blue: channel(2)),
            gpuMilliseconds: (commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1000
        )
    }

    /// Red, yellow, green, cyan, blue and magenta at 75% (first six) and 100%, in vectorscope bins.
    static func barTargets(coefficients: YCbCrCoefficients) -> [SIMD2<Float>] {
        let colors: [SIMD3<Float>] = [[1, 0, 0], [1, 1, 0], [0, 1, 0], [0, 1, 1], [0, 0, 1], [1, 0, 1]]
        let kr = Float(coefficients.kr), kb = Float(coefficients.kb)
        return [Float(0.75), 1].flatMap { level in
            colors.map { color -> SIMD2<Float> in
                let c = color * level
                let y = kr * c.x + (1 - kr - kb) * c.y + kb * c.z
                let bin = vectorscopeBin(cb: (c.z - y) / (2 * (1 - kb)), cr: (c.x - y) / (2 * (1 - kr)), size: size)
                return SIMD2(Float(bin.u), Float(bin.v))
            }
        }
    }

    /// The skin-tone ("I") line, 123° counterclockwise from +Cb, in image coordinates (y down).
    static let skinToneDirection: SIMD2<Float> = {
        let angle = Float(123) * .pi / 180
        return SIMD2(cos(angle), -sin(angle))
    }()

    private func dispatch(_ encoder: MTLComputeCommandEncoder, _ width: Int, _ height: Int) {
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
    }

    private static func image(_ texture: MTLTexture) throws -> CGImage {
        let width = texture.width, height = texture.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw VideoColorError.noMetalDevice }
        return image
    }
}
