@preconcurrency import CoreVideo
import Foundation
import Metal

struct YCbCrCoefficients: Equatable, Sendable {
    var kr: Double
    var kb: Double
}

extension YCbCrMatrix {
    /// Luma coefficients. A frame with no matrix label is taken as Rec. 709, as players do for HD.
    var coefficients: YCbCrCoefficients {
        switch self {
        case .rec709, .unknown: YCbCrCoefficients(kr: 0.2126, kb: 0.0722)
        case .rec601: YCbCrCoefficients(kr: 0.299, kb: 0.114)
        case .rec2020: YCbCrCoefficients(kr: 0.2627, kb: 0.0593)
        }
    }
}

/// What a bi-planar Y'CbCr pixel format says about its samples. The buffer's own format is the
/// truth about range: full-range sources arrive as `xf22`/`xf20`, never as video-range with an
/// offset (the Task 0 decision record found `x422` from a full-range file is shifted by 64).
struct YCbCrBufferLayout: Equatable, Sendable {
    var bitDepth: Int
    var isFullRange: Bool
    var chromaSubsamplingX: Int
    var chromaSubsamplingY: Int

    init(bitDepth: Int, isFullRange: Bool, chromaSubsamplingX: Int, chromaSubsamplingY: Int) {
        self.bitDepth = bitDepth
        self.isFullRange = isFullRange
        self.chromaSubsamplingX = chromaSubsamplingX
        self.chromaSubsamplingY = chromaSubsamplingY
    }

    init?(pixelFormat: OSType) {
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: self.init(bitDepth: 8, isFullRange: false, chromaSubsamplingX: 2, chromaSubsamplingY: 2)
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: self.init(bitDepth: 8, isFullRange: true, chromaSubsamplingX: 2, chromaSubsamplingY: 2)
        case kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange: self.init(bitDepth: 8, isFullRange: false, chromaSubsamplingX: 2, chromaSubsamplingY: 1)
        case kCVPixelFormatType_422YpCbCr8BiPlanarFullRange: self.init(bitDepth: 8, isFullRange: true, chromaSubsamplingX: 2, chromaSubsamplingY: 1)
        case kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange: self.init(bitDepth: 8, isFullRange: false, chromaSubsamplingX: 1, chromaSubsamplingY: 1)
        case kCVPixelFormatType_444YpCbCr8BiPlanarFullRange: self.init(bitDepth: 8, isFullRange: true, chromaSubsamplingX: 1, chromaSubsamplingY: 1)
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange: self.init(bitDepth: 10, isFullRange: false, chromaSubsamplingX: 2, chromaSubsamplingY: 2)
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: self.init(bitDepth: 10, isFullRange: true, chromaSubsamplingX: 2, chromaSubsamplingY: 2)
        case kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange: self.init(bitDepth: 10, isFullRange: false, chromaSubsamplingX: 2, chromaSubsamplingY: 1)
        case kCVPixelFormatType_422YpCbCr10BiPlanarFullRange: self.init(bitDepth: 10, isFullRange: true, chromaSubsamplingX: 2, chromaSubsamplingY: 1)
        case kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange: self.init(bitDepth: 10, isFullRange: false, chromaSubsamplingX: 1, chromaSubsamplingY: 1)
        case kCVPixelFormatType_444YpCbCr10BiPlanarFullRange: self.init(bitDepth: 10, isFullRange: true, chromaSubsamplingX: 1, chromaSubsamplingY: 1)
        default: return nil
        }
    }

    var lumaFormat: MTLPixelFormat { bitDepth > 8 ? .r16Unorm : .r8Unorm }
    var chromaFormat: MTLPixelFormat { bitDepth > 8 ? .rg16Unorm : .rg8Unorm }
}

/// Mirrors `DecodeParameters` in the shader source: eleven 4-byte floats.
private struct DecodeParameters {
    var codeScale: Float
    var yOffset: Float
    var yScale: Float
    var cOffset: Float
    var cScale: Float
    var kr: Float
    var kb: Float
    var chromaSubX: Float
    var chromaSubY: Float
    var sitingX: Float
    var sitingY: Float

    init(layout: YCbCrBufferLayout, coefficients: YCbCrCoefficients) {
        let depth = layout.bitDepth
        // 10-bit samples sit in the top 10 bits of 16, so the unorm value times 65535/64 is the code.
        codeScale = depth > 8 ? 65535.0 / 64.0 : 255
        let shift = Float(1 << (depth - 8))
        if layout.isFullRange {
            let top = Float((1 << depth) - 1)
            (yOffset, yScale, cOffset, cScale) = (0, top, 128 * shift, top)
        } else {
            (yOffset, yScale, cOffset, cScale) = (16 * shift, 219 * shift, 128 * shift, 224 * shift)
        }
        kr = Float(coefficients.kr)
        kb = Float(coefficients.kb)
        chromaSubX = Float(layout.chromaSubsamplingX)
        chromaSubY = Float(layout.chromaSubsamplingY)
        // Left siting, as in H.264 and HEVC camera files: horizontally on the first luma pixel of a
        // pair, and for 4:2:0 vertically between the two rows.
        sitingX = 0
        sitingY = layout.chromaSubsamplingY == 2 ? 0.5 : 0
    }
}

/// Mirrors `EncodeParameters` in the shader source: nine 4-byte floats.
private struct EncodeParameters {
    var kr: Float
    var kb: Float
    var yOffset: Float = 64
    var yScale: Float = 876
    var cOffset: Float = 512
    var cScale: Float = 896
    var minCode: Float = 4 // ProRes keeps codes 0-3 and 1020-1023 for sync.
    var maxCode: Float = 1019
    var unormPerCode: Float = 64.0 / 65535.0
}

/// Y'CbCr ⇄ R'G'B' half-float conversion and fitting on the GPU.
///
/// Working frames are `rgba16Float` textures holding gamma-encoded R'G'B' that is not clamped, so
/// super-white and out-of-gamut values survive for grading. Every call only encodes onto the
/// caller's command buffer; the caller commits and decides when to wait.
final class VideoColorKernels: @unchecked Sendable {
    let runtime: MetalPipelineCache

    init(runtime: MetalPipelineCache? = MetalPipelineCache.shared) throws {
        guard let runtime else { throw VideoColorError.noMetalDevice }
        self.runtime = runtime
        try runtime.prepare()
    }

    func makeWorkingTexture(width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        guard let texture = runtime.device.makeTexture(descriptor: descriptor) else { throw VideoColorError.noMetalDevice }
        return texture
    }

    /// Decodes a bi-planar Y'CbCr frame into `output` (same size as the frame).
    func decode(_ buffer: CVPixelBuffer, matrix: YCbCrMatrix, into output: MTLTexture, commandBuffer: MTLCommandBuffer) throws {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard let layout = YCbCrBufferLayout(pixelFormat: format) else { throw VideoColorError.unsupportedPixelFormat(format) }
        guard output.width == CVPixelBufferGetWidth(buffer), output.height == CVPixelBufferGetHeight(buffer) else {
            throw VideoColorError.sizeMismatch("\(CVPixelBufferGetWidth(buffer))×\(CVPixelBufferGetHeight(buffer)) frame into a \(output.width)×\(output.height) texture")
        }
        let luma = try runtime.texture(for: buffer, plane: 0, format: layout.lumaFormat)
        let chroma = try runtime.texture(for: buffer, plane: 1, format: layout.chromaFormat)
        var parameters = DecodeParameters(layout: layout, coefficients: matrix.coefficients)

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw VideoColorError.noMetalDevice }
        encoder.setComputePipelineState(try runtime.pipeline(named: "decodeYCbCr"))
        encoder.setTexture(luma.texture, index: 0)
        encoder.setTexture(chroma.texture, index: 1)
        encoder.setTexture(output, index: 2)
        encoder.setBytes(&parameters, length: MemoryLayout<DecodeParameters>.stride, index: 0)
        dispatch(encoder, width: output.width, height: output.height)
        encoder.endEncoding()
        // The CoreVideo wrappers must outlive the GPU work that reads them.
        let owners = [luma.owner, chroma.owner]
        commandBuffer.addCompletedHandler { _ in withExtendedLifetime(owners) {} }
    }

    /// Encodes `input` as video-range 10-bit 4:2:2 (`x422`) with co-sited chroma, clamped to the
    /// codes ProRes allows. `output` must be the same size as `input`.
    func encodeVideoRange422(_ input: MTLTexture, matrix: YCbCrMatrix, into output: CVPixelBuffer, commandBuffer: MTLCommandBuffer) throws {
        let format = CVPixelBufferGetPixelFormatType(output)
        guard format == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange else { throw VideoColorError.unsupportedPixelFormat(format) }
        guard input.width == CVPixelBufferGetWidth(output), input.height == CVPixelBufferGetHeight(output) else {
            throw VideoColorError.sizeMismatch("\(input.width)×\(input.height) texture into a \(CVPixelBufferGetWidth(output))×\(CVPixelBufferGetHeight(output)) frame")
        }
        let luma = try runtime.texture(for: output, plane: 0, format: .r16Unorm)
        let chroma = try runtime.texture(for: output, plane: 1, format: .rg16Unorm)
        let coefficients = matrix.coefficients
        var parameters = EncodeParameters(kr: Float(coefficients.kr), kb: Float(coefficients.kb))

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw VideoColorError.noMetalDevice }
        encoder.setTexture(input, index: 0)
        encoder.setBytes(&parameters, length: MemoryLayout<EncodeParameters>.stride, index: 0)
        encoder.setComputePipelineState(try runtime.pipeline(named: "encodeLuma"))
        encoder.setTexture(luma.texture, index: 1)
        dispatch(encoder, width: luma.texture.width, height: luma.texture.height)
        encoder.setComputePipelineState(try runtime.pipeline(named: "encodeChroma422"))
        encoder.setTexture(chroma.texture, index: 1)
        dispatch(encoder, width: chroma.texture.width, height: chroma.texture.height)
        encoder.endEncoding()
        let owners = [luma.owner, chroma.owner]
        commandBuffer.addCompletedHandler { _ in withExtendedLifetime(owners) {} }
    }

    /// Scales `source` to fit inside `output`, keeping its aspect ratio, on black. Bilinear, so it
    /// is meant for fitting a frame to the render size, not for large reductions.
    func fit(_ source: MTLTexture, into output: MTLTexture, commandBuffer: MTLCommandBuffer) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder(),
              let pipeline = try? runtime.pipeline(named: "fitToRenderSize") else { return }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(output, index: 1)
        dispatch(encoder, width: output.width, height: output.height)
        encoder.endEncoding()
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, width: Int, height: Int) {
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)
        )
    }
}
