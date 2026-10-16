@preconcurrency import CoreVideo
import Foundation
import Metal

enum VideoColorError: LocalizedError {
    case noMetalDevice
    case shaderCompilationFailed(String)
    case missingFunction(String)
    case unsupportedPixelFormat(OSType)
    case textureCreationFailed(CVReturn)
    case sizeMismatch(String)

    var errorDescription: String? {
        switch self {
        case .noMetalDevice: "This Mac has no Metal device."
        case .shaderCompilationFailed(let log): "The video color shaders did not compile: \(log)"
        case .missingFunction(let name): "The shader function \(name) is missing."
        case .unsupportedPixelFormat(let format): "Pixel format \(format) is not a supported video format."
        case .textureCreationFailed(let status): "A video frame could not be shared with the GPU (CoreVideo status \(status))."
        case .sizeMismatch(let reason): "Frame sizes do not match: \(reason)"
        }
    }
}

/// One Metal device, one command queue, the compiled video color library, and a CoreVideo texture
/// cache, shared by everything that processes video frames. Pipelines compile on first use and are
/// reused; compiling takes tens of milliseconds, so the first frame can pay it off the main actor
/// (`prepare()` does so ahead of time).
///
/// Unlike an actor, this is callable from the compositor's synchronous request queue. Its mutable
/// state is behind `lock`.
final class MetalPipelineCache: @unchecked Sendable {
    static let shared: MetalPipelineCache? = try? MetalPipelineCache()

    let device: MTLDevice
    let queue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let lock = NSLock()
    private var library: MTLLibrary?
    private var pipelines: [String: MTLComputePipelineState] = [:]

    init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device, let queue = device.makeCommandQueue() else { throw VideoColorError.noMetalDevice }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else {
            throw VideoColorError.noMetalDevice
        }
        self.device = device
        self.queue = queue
        textureCache = cache
    }

    /// Compiles the library and every kernel now, so the first frame does not.
    func prepare() throws {
        for name in ["decodeYCbCr", "encodeLuma", "encodeChroma422", "fitToRenderSize"] { _ = try pipeline(named: name) }
    }

    func pipeline(named name: String) throws -> MTLComputePipelineState {
        lock.lock()
        defer { lock.unlock() }
        if let cached = pipelines[name] { return cached }
        let library = try loadLibrary()
        guard let function = library.makeFunction(name: name) else { throw VideoColorError.missingFunction(name) }
        let pipeline = try device.makeComputePipelineState(function: function)
        pipelines[name] = pipeline
        return pipeline
    }

    /// Wraps one plane of an IOSurface-backed pixel buffer as a texture without copying. The returned
    /// `CVMetalTexture` must stay alive until the GPU has finished with the texture.
    func texture(for buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) throws -> (texture: MTLTexture, owner: CVMetalTexture) {
        var created: CVMetalTexture?
        lock.lock()
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, buffer, nil, format,
            CVPixelBufferGetWidthOfPlane(buffer, plane), CVPixelBufferGetHeightOfPlane(buffer, plane), plane, &created
        )
        lock.unlock()
        guard status == kCVReturnSuccess, let created, let texture = CVMetalTextureGetTexture(created) else {
            throw VideoColorError.textureCreationFailed(status)
        }
        return (texture, created)
    }

    /// Releases CoreVideo's cached textures, for memory pressure.
    func flush() {
        lock.lock()
        defer { lock.unlock() }
        CVMetalTextureCacheFlush(textureCache, 0)
    }

    private func loadLibrary() throws -> MTLLibrary {
        if let library { return library }
        let options = MTLCompileOptions()
        options.languageVersion = .version2_4 // What Task 0 verified for OCIO's generated shaders too.
        do {
            let compiled = try device.makeLibrary(source: MetalShaderSources.videoColor, options: options)
            library = compiled
            return compiled
        } catch {
            throw VideoColorError.shaderCompilationFailed(error.localizedDescription)
        }
    }
}
