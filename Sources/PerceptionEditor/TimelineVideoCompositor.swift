@preconcurrency import AVFoundation
import CoreVideo
import Foundation
import Metal
import OSLog

/// Counters for one composition's compositor, read by tests through `statisticsKey`.
struct CompositorStatistics: Equatable, CustomStringConvertible, Sendable {
    var started = 0
    var finished = 0
    var cancelled = 0
    var failed = 0
    var inFlight = 0
    var maximumInFlight = 0
    /// GPU time of each finished frame (`gpuEndTime − gpuStartTime`), the most recent `gpuSampleLimit`.
    var gpuMilliseconds: [Double] = []
    static let gpuSampleLimit = 20_000

    /// Requests AVFoundation has handed over that have not been answered.
    var pending: Int { started - finished - cancelled - failed }

    var medianGPUMilliseconds: Double? { gpuMilliseconds.isEmpty ? nil : gpuMilliseconds.sorted()[gpuMilliseconds.count / 2] }
    var maximumGPUMilliseconds: Double? { gpuMilliseconds.max() }

    var description: String {
        let gpu = medianGPUMilliseconds.map { String(format: ", GPU median %.2f ms, max %.2f ms", $0, maximumGPUMilliseconds ?? 0) } ?? ""
        return "started \(started), finished \(finished), cancelled \(cancelled), failed \(failed), max in flight \(maximumInFlight)\(gpu)"
    }

    mutating func recordGPU(_ milliseconds: Double) {
        if gpuMilliseconds.count >= Self.gpuSampleLimit { gpuMilliseconds.removeFirst(gpuMilliseconds.count - Self.gpuSampleLimit + 1) }
        gpuMilliseconds.append(milliseconds)
    }
}

private final class CompositorStatisticsStore: @unchecked Sendable {
    static let shared = CompositorStatisticsStore()
    private let lock = NSLock()
    private var values: [UUID: CompositorStatistics] = [:]

    func update(_ key: UUID?, _ change: (inout CompositorStatistics) -> Void) {
        guard let key else { return }
        lock.lock()
        defer { lock.unlock() }
        change(&values[key, default: CompositorStatistics()])
    }

    func statistics(for key: UUID) -> CompositorStatistics {
        lock.lock()
        defer { lock.unlock() }
        return values[key] ?? CompositorStatistics()
    }
}

/// Everything a frame needs from the GPU side, shared by every compositor instance: one device and
/// queue, the color kernels, a bounded pool of working frames, and the Core Image grade stage.
final class VideoCompositingEngine: @unchecked Sendable {
    static let shared: VideoCompositingEngine? = try? VideoCompositingEngine()
    /// Whether the compositor can run, without building the engine (which compiles shaders).
    static let isSupported = MTLCreateSystemDefaultDevice() != nil

    /// Builds the engine and compiles the video and Core Image color kernels. It takes from a few
    /// hundred milliseconds to seconds with a cold shader cache, so call it off the main actor.
    static func prepare() {
        _ = shared
        _ = HSLColorKernel.isAvailable
        _ = LUTKernel.isAvailable
        _ = OCIOColorKernels.shared
    }
    /// Set once the engine exists, so memory pressure can release its textures without creating it.
    nonisolated(unsafe) private static weak var created: VideoCompositingEngine?

    let kernels: VideoColorKernels
    let pool: VideoTexturePool
    let grader: ColorGradeStage

    init() throws {
        kernels = try VideoColorKernels()
        pool = VideoTexturePool(device: kernels.runtime.device)
        grader = ColorGradeStage(queue: kernels.runtime.queue)
        Self.created = self
    }

    /// Drops the waiting working frames, CoreVideo's cached textures, Core Image's caches and the
    /// scope captures. Frames being rendered keep what they hold until the GPU is done with them.
    static func releaseMemoryUnderPressure() {
        ScopeTap.shared.releaseTextures()
        guard let engine = created else { return }
        let waiting = engine.pool.freeCount
        engine.pool.flush()
        engine.kernels.runtime.flush()
        engine.grader.clearCaches()
        VideoCompositorDiagnostics.record("memory pressure: released \(waiting) waiting frames, the texture cache and Core Image's caches")
    }

    /// What an encoded frame keeps alive until the GPU is done with it.
    struct FrameResources {
        var pooled: [MTLTexture] = []
        var owners: [CVMetalTexture] = []
        /// A small copy for the scopes, to publish once the GPU has written it.
        var scopeCapture: MTLTexture?
    }

    /// Encodes one frame onto `commandBuffer`: decode, fit and grade the source (or fill black when
    /// there is no clip), then write `output` in its own format. The caller commits.
    ///
    /// Intermediate frames are only as large as they must be: a neutral, upright clip already at the
    /// render size decodes straight into the output texture.
    func encode(
        source: CVPixelBuffer?, recipe: ClipRenderRecipe?, output: CVPixelBuffer, commandBuffer: MTLCommandBuffer,
        compositionSeconds: Double? = nil, scopeTap: ScopeTap = .shared
    ) throws -> FrameResources {
        var resources = FrameResources()
        func temporary(_ width: Int, _ height: Int) -> MTLTexture {
            let texture = pool.acquire(width: width, height: height)
            resources.pooled.append(texture)
            return texture
        }

        let outputFormat = CVPixelBufferGetPixelFormatType(output)
        let renderWidth = CVPixelBufferGetWidth(output), renderHeight = CVPixelBufferGetHeight(output)
        let final: MTLTexture
        if outputFormat == kCVPixelFormatType_64RGBAHalf {
            let wrapped = try kernels.runtime.texture(for: output, plane: 0, format: .rgba16Float)
            resources.owners.append(wrapped.owner)
            final = wrapped.texture
        } else {
            final = temporary(renderWidth, renderHeight)
        }

        do {
            // Only preview frames feed the scopes, and only while the scope panel is open.
            let tap = outputFormat == kCVPixelFormatType_64RGBAHalf && scopeTap.shouldCapture(compositionSeconds: compositionSeconds)
                ? scopeTap : nil
            guard let source, let recipe else {
                try kernels.fillBlack(final, commandBuffer: commandBuffer)
                if let tap { try capture(final, for: tap, commandBuffer: commandBuffer, resources: &resources) }
                try finish(final, into: output, outputFormat: outputFormat, commandBuffer: commandBuffer, resources: &resources)
                return resources
            }
            let sourceWidth = CVPixelBufferGetWidth(source), sourceHeight = CVPixelBufferGetHeight(source)
            let needsFit = !(recipe.orientation.isIdentity && sourceWidth == renderWidth && sourceHeight == renderHeight)
            // Without OCIO's shaders (they failed to compile) log footage shows as recorded; the
            // composition has already warned.
            let ocio = recipe.ocioInput.flatMap { _ in OCIOColorKernels.shared }
            let needsGrade = ocio != nil || recipe.adjustments != .neutral || recipe.inputLUT != nil

            // Each stage writes the next stage's input; the last writes `final`.
            let decoded = (needsFit || needsGrade) ? temporary(sourceWidth, sourceHeight) : final
            if !needsFit && !needsGrade {
                try kernels.decode(source, matrix: recipe.matrix, into: final, commandBuffer: commandBuffer)
            } else {
                try kernels.decode(source, matrix: recipe.matrix, into: decoded, commandBuffer: commandBuffer)
                var current = decoded
                if needsFit {
                    let fitted = needsGrade ? temporary(renderWidth, renderHeight) : final
                    try kernels.fit(current, orientation: recipe.orientation, into: fitted, commandBuffer: commandBuffer)
                    current = fitted
                }
                if let ocio, let transform = recipe.ocioInput {
                    if recipe.adjustments.isUntouched {
                        try ocio.toDisplay(current, from: transform, into: final, commandBuffer: commandBuffer)
                    } else {
                        // Grade in scene-linear Rec. 709, between OCIO's input and output transforms.
                        let linear = temporary(renderWidth, renderHeight), graded = temporary(renderWidth, renderHeight)
                        try ocio.toSceneLinear(current, from: transform, into: linear, commandBuffer: commandBuffer)
                        guard grader.grade(linear, adjustments: recipe.adjustments, sceneLinear: true, into: graded, commandBuffer: commandBuffer) else {
                            throw VideoColorError.textureCreationFailed(kCVReturnError)
                        }
                        try ocio.toDisplay(graded, into: final, commandBuffer: commandBuffer)
                    }
                } else if needsGrade {
                    guard grader.grade(current, adjustments: recipe.adjustments, inputLUT: recipe.inputLUT, into: final, commandBuffer: commandBuffer) else {
                        throw VideoColorError.textureCreationFailed(kCVReturnError)
                    }
                }
            }
            if let tap {
                // "Source" shows the decoded code values (log footage as recorded), before any
                // input LUT or grade; when nothing follows the decode, that is the output itself.
                try capture(tap.source == .source ? decoded : final, for: tap, commandBuffer: commandBuffer, resources: &resources)
            }
            try finish(final, into: output, outputFormat: outputFormat, commandBuffer: commandBuffer, resources: &resources)
            return resources
        } catch {
            release(resources)
            throw error
        }
    }

    private func capture(_ frame: MTLTexture, for tap: ScopeTap, commandBuffer: MTLCommandBuffer, resources: inout FrameResources) throws {
        let width = ScopeTap.captureWidth // A fixed width, so the waveform columns mean the same at any render size.
        let height = max(1, Int((Double(frame.height) * Double(width) / Double(frame.width)).rounded()))
        guard let target = tap.captureTexture(device: kernels.runtime.device, width: width, height: height) else { return }
        try kernels.downsampleForScope(frame, into: target, commandBuffer: commandBuffer)
        resources.scopeCapture = target
    }

    func release(_ resources: FrameResources) {
        resources.pooled.forEach(pool.release)
    }

    private func finish(
        _ final: MTLTexture, into output: CVPixelBuffer, outputFormat: OSType,
        commandBuffer: MTLCommandBuffer, resources: inout FrameResources
    ) throws {
        guard outputFormat != kCVPixelFormatType_64RGBAHalf else { return }
        // Export frames are video-range 10-bit 4:2:2 in Rec. 709, as the composition is tagged.
        try kernels.encodeVideoRange422(final, matrix: .rec709, into: output, commandBuffer: commandBuffer)
    }
}

private struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
}

/// The `AVVideoCompositing` that renders the timeline. It receives the stored frame of each clip in
/// whatever 8/10-bit Y'CbCr format the file uses (never 32BGRA), processes it in half float on
/// Metal, and answers in `outputPixelFormat`.
///
/// Requests arrive on arbitrary threads. Each is queued onto a private serial queue, limited to two
/// frames on the GPU at once, and answered from the command buffer's completion handler.
/// `cancelAllPendingVideoCompositionRequests` bumps a generation so queued and in-flight requests
/// answer "cancelled", then waits until every request has been answered.
class TimelineVideoCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    /// Preview and export differ only in the pixel format they hand back.
    class var outputPixelFormat: OSType { kCVPixelFormatType_64RGBAHalf }

    /// Every bi-planar Y'CbCr format the color kernels read. A format missing here would be converted
    /// by AVFoundation, color space included, before the compositor saw it.
    static let sourceFormats: [OSType] = [
        kCVPixelFormatType_422YpCbCr10BiPlanarFullRange, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        kCVPixelFormatType_444YpCbCr10BiPlanarFullRange, kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr8BiPlanarFullRange
    ]

    static let maximumFramesInFlight = 2

    static func statistics(for key: UUID) -> CompositorStatistics {
        CompositorStatisticsStore.shared.statistics(for: key)
    }

    private let queue = DispatchQueue(label: "PerceptionEditor.TimelineVideoCompositor", qos: .userInitiated)
    private let gpuSlots = DispatchSemaphore(value: TimelineVideoCompositor.maximumFramesInFlight)
    private let unanswered = DispatchGroup()
    private let lock = NSLock()
    private var generation = 0

    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [
            kCVPixelBufferPixelFormatTypeKey as String: Self.sourceFormats,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: Self.outputPixelFormat,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
    }

    var supportsWideColorSourceFrames: Bool { true }
    var supportsHDRSourceFrames: Bool { false }
    var canConformColorOfSourceFrames: Bool { true }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        let box = Unchecked(value: request)
        let key = (request.videoCompositionInstruction as? TimelineCompositionInstruction)?.statisticsKey
        let expected = currentGeneration()
        let signposter = VideoCompositorDiagnostics.signposter
        let interval = signposter.beginInterval("Frame", id: signposter.makeSignpostID(), "\(request.compositionTime.seconds, format: .fixed(precision: 3)) s")
        unanswered.enter()
        CompositorStatisticsStore.shared.update(key) { $0.started += 1 }
        queue.async { [self] in render(box.value, key: key, generation: expected, interval: interval) }
    }

    func cancelAllPendingVideoCompositionRequests() {
        lock.lock()
        generation += 1
        lock.unlock()
        // Queued requests see the new generation and answer "cancelled"; frames already on the GPU
        // finish within milliseconds and answer from their completion handlers.
        _ = unanswered.wait(timeout: .now() + 2)
    }

    private func currentGeneration() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    private enum Answer {
        case frame(CVPixelBuffer)
        case cancelled
        case failure(any Error)
    }

    private func answer(_ request: AVAsynchronousVideoCompositionRequest, key: UUID?, interval: OSSignpostIntervalState, _ answer: Answer) {
        let signposter = VideoCompositorDiagnostics.signposter
        let time = request.compositionTime.seconds
        switch answer {
        case .frame(let buffer):
            CompositorStatisticsStore.shared.update(key) { $0.finished += 1 }
            signposter.endInterval("Frame", interval, "finished")
            request.finish(withComposedVideoFrame: buffer)
        case .cancelled:
            CompositorStatisticsStore.shared.update(key) { $0.cancelled += 1 }
            signposter.endInterval("Frame", interval, "cancelled")
            VideoCompositorDiagnostics.record(String(format: "frame %.3f s cancelled", time))
            request.finishCancelledRequest()
        case .failure(let error):
            CompositorStatisticsStore.shared.update(key) { $0.failed += 1 }
            signposter.endInterval("Frame", interval, "failed")
            VideoCompositorDiagnostics.record(String(format: "frame %.3f s failed: ", time) + error.localizedDescription)
            request.finish(with: error)
        }
        unanswered.leave()
    }

    private func render(_ request: AVAsynchronousVideoCompositionRequest, key: UUID?, generation expected: Int, interval: OSSignpostIntervalState) {
        guard currentGeneration() == expected else { return answer(request, key: key, interval: interval, .cancelled) }
        guard let engine = VideoCompositingEngine.shared else { return answer(request, key: key, interval: interval, .failure(VideoColorError.noMetalDevice)) }
        guard let instruction = request.videoCompositionInstruction as? TimelineCompositionInstruction else {
            return answer(request, key: key, interval: interval, .failure(VideoColorError.sizeMismatch("an instruction that is not a timeline instruction")))
        }
        guard let output = request.renderContext.newPixelBuffer() else {
            return answer(request, key: key, interval: interval, .failure(VideoColorError.textureCreationFailed(kCVReturnAllocationFailed)))
        }
        let source = instruction.recipe == nil ? nil : request.sourceFrame(byTrackID: instruction.sourceTrackID)

        gpuSlots.wait()
        guard currentGeneration() == expected else {
            gpuSlots.signal()
            return answer(request, key: key, interval: interval, .cancelled)
        }
        guard let commandBuffer = engine.kernels.runtime.queue.makeCommandBuffer() else {
            gpuSlots.signal()
            return answer(request, key: key, interval: interval, .failure(VideoColorError.noMetalDevice))
        }
        do {
            // A clip whose frame is missing shows black rather than stopping playback.
            let resources = try autoreleasepool {
                try engine.encode(
                    source: source, recipe: source == nil ? nil : instruction.recipe, output: output, commandBuffer: commandBuffer,
                    compositionSeconds: request.compositionTime.seconds, scopeTap: instruction.scopeTap
                )
            }
            CompositorStatisticsStore.shared.update(key) {
                $0.inFlight += 1
                $0.maximumInFlight = max($0.maximumInFlight, $0.inFlight)
            }
            let box = Unchecked(value: request)
            let held = Unchecked(value: (source, output, resources))
            commandBuffer.addCompletedHandler { [self] buffer in
                engine.release(held.value.2)
                let gpuMilliseconds = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
                VideoCompositorDiagnostics.signposter.emitEvent("GPU", "\(gpuMilliseconds, format: .fixed(precision: 2)) ms")
                CompositorStatisticsStore.shared.update(key) {
                    $0.inFlight -= 1
                    if buffer.status == .completed { $0.recordGPU(gpuMilliseconds) }
                }
                VideoCompositorDiagnostics.record(String(format: "frame %.3f s GPU %.2f ms", box.value.compositionTime.seconds, gpuMilliseconds))
                gpuSlots.signal()
                if currentGeneration() != expected {
                    answer(box.value, key: key, interval: interval, .cancelled)
                } else if buffer.status == .completed {
                    if let capture = held.value.2.scopeCapture { instruction.scopeTap.publish(capture) }
                    answer(box.value, key: key, interval: interval, .frame(held.value.1))
                } else {
                    answer(box.value, key: key, interval: interval, .failure(buffer.error ?? VideoColorError.noMetalDevice))
                }
                withExtendedLifetime(held) {}
            }
            commandBuffer.commit()
        } catch {
            gpuSlots.signal()
            answer(request, key: key, interval: interval, .failure(error))
        }
    }
}

final class PreviewVideoCompositor: TimelineVideoCompositor, @unchecked Sendable {
    override class var outputPixelFormat: OSType { kCVPixelFormatType_64RGBAHalf }
}

final class ExportVideoCompositor: TimelineVideoCompositor, @unchecked Sendable {
    override class var outputPixelFormat: OSType { kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange }
}
