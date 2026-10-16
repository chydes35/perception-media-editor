// Sources/PerceptionEditor/ProxyGenerator.swift
@preconcurrency import AVFoundation
import Foundation
import Synchronization
import VideoToolbox

struct ProxyInfo: Equatable, Sendable {
    var url: URL
    var frameCount: Int
    var pixelWidth: Int
    var pixelHeight: Int
}

enum ProxyError: LocalizedError, Equatable {
    case noVideoTrack
    case readFailed(String)
    case writeFailed(String)
    case validationFailed(String)
    case insufficientSpace(neededBytes: Int64, availableBytes: Int64)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: "The file has no video track."
        case .readFailed(let reason): "The original could not be read: \(reason)"
        case .writeFailed(let reason): "The proxy could not be written: \(reason)"
        case .validationFailed(let reason): "The proxy did not match the original: \(reason)"
        case .insufficientSpace(let needed, let available):
            "Not enough free space for a proxy (needs \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)), \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) free)."
        }
    }
}

/// Fault injection for the sample loop, used only by tests. AVFoundation offers no reliable way to make a
/// writer fail while the input has stopped asking for data, so tests simulate that stall here.
struct ProxyGenerationFaults: Sendable {
    /// After this many appended frames the loop stops pulling and ignores further callbacks, as if
    /// the input had stopped asking for data.
    var stallAfterFrames: Int?
    /// How often a running job rechecks reader and writer health; nil turns the watchdog off.
    var watchdogInterval: DispatchTimeInterval? = .seconds(1)
    /// Replaces the real reader/writer status check.
    var pipelineFailure: (@Sendable () -> ProxyError?)?

    static let none = ProxyGenerationFaults()
}

/// Transcodes one original into a ProRes 422 Proxy for editing. Frames are read as 10-bit 4:2:2;
/// asking the decoder for BGRA cut throughput to a quarter on the target M1 (12 fps vs 45 fps).
///
/// Full-range sources (the S5 records V-Log in full range) are read as full-range 10-bit and
/// converted to video range by VideoToolbox. Reading them as video-range `x422` instead makes
/// AVFoundation add 64 to luma without rescaling, so the proxy played about 17% brighter than the
/// original and clipped above original code 876 (docs/decisions/2026-10-16-10bit-compositor.md).
enum ProxyGenerator {
    static let defaultMaximumSize = CGSize(width: 1920, height: 1080)
    /// Measured on Lumix S5 UHD 23.976 footage: 44 MB per 10 s of 1080p ProRes 422 Proxy.
    static let bytesPerSecondAt1080p: Double = 4_500_000
    /// Generation is background work: one job at a time, never competing with editing for the CPU.
    static let workQoS: DispatchQoS = .utility

    static func proxySize(for source: CGSize, maximum: CGSize = defaultMaximumSize) -> CGSize {
        guard source.width > 0, source.height > 0 else { return maximum }
        let scale = min(1, maximum.width / source.width, maximum.height / source.height)
        func even(_ value: CGFloat) -> CGFloat { max(2, (value * scale / 2).rounded() * 2) }
        return CGSize(width: even(source.width), height: even(source.height))
    }

    static func estimatedBytes(durationSeconds: Double, proxySize: CGSize) -> Int64 {
        let pixelRatio = (proxySize.width * proxySize.height) / (1920 * 1080)
        return Int64(max(0, durationSeconds) * bytesPerSecondAt1080p * Double(pixelRatio))
    }

    static func generate(
        source: URL,
        destination: URL,
        maximumSize: CGSize = defaultMaximumSize,
        faults: ProxyGenerationFaults = .none,
        progress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> ProxyInfo {
        let fileManager = FileManager.default
        let partial = destination.deletingPathExtension().appendingPathExtension("partial.mov")
        try? fileManager.removeItem(at: partial)
        defer { try? fileManager.removeItem(at: partial) } // Already moved on success.

        let asset = AVURLAsset(url: source)
        let tracks: [AVAssetTrack]
        do { tracks = try await asset.loadTracks(withMediaType: .video) } catch {
            try Task.checkCancellation() // A cancelled load must stay a cancellation, not "no video track".
            throw ProxyError.noVideoTrack
        }
        guard let track = tracks.first else { throw ProxyError.noVideoTrack }
        let (naturalSize, transform, timeRange, formats) = try await track.load(
            .naturalSize, .preferredTransform, .timeRange, .formatDescriptions
        )
        try Task.checkCancellation()
        let size = proxySize(for: naturalSize, maximum: maximumSize)

        let isFullRange = formats.first.map(isFullRangeVideo) ?? false

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: isFullRange
            ? [
                // The reader scales, so the range conversion runs on proxy-sized frames.
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ]
            : [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange]
        )
        output.alwaysCopiesSampleData = false
        reader.add(output)

        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: partial, fileType: .mov) } catch {
            throw ProxyError.writeFailed(error.localizedDescription)
        }
        var settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.proRes422Proxy,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect
        ]
        if let format = formats.first, let colors = colorProperties(format) {
            settings[AVVideoColorPropertiesKey] = colors
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.transform = transform
        input.expectsMediaDataInRealTime = false
        let conversion = isFullRange ? try VideoRangeConversion(input: input, size: size) : nil
        writer.add(input)

        guard reader.startReading() else {
            throw ProxyError.readFailed(reader.error?.localizedDescription ?? "unknown error")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw ProxyError.writeFailed(writer.error?.localizedDescription ?? "unknown error")
        }
        writer.startSession(atSourceTime: timeRange.start)

        // The sample loop blocks inside AVFoundation, so it runs on its own serial queue instead of
        // the cooperative pool; parallel jobs would otherwise starve every pool thread.
        let job = SampleCopyJob(
            reader: reader, output: output, writer: writer, input: input, conversion: conversion,
            start: timeRange.start, total: max(timeRange.duration.seconds, 0.001), faults: faults
        )
        let written = try await withoutActuallyEscaping(progress) { progress in
            // Only the job holds `progress`, and `finish` drops it before resuming, so it never outlives this call.
            job.setProgress(progress)
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    job.queue.async { job.begin(continuation) }
                }
            } onCancel: {
                job.cancel()
            }
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw ProxyError.writeFailed(writer.error?.localizedDescription ?? "finish failed")
        }

        let proxyFrames = try await frameCount(at: partial)
        guard proxyFrames == written, written > 0 else {
            throw ProxyError.validationFailed("\(proxyFrames) proxy frames, \(written) source frames")
        }
        let proxyTrack = try await AVURLAsset(url: partial).loadTracks(withMediaType: .video)[0]
        let proxyRange = try await proxyTrack.load(.timeRange)
        let frameSeconds = 1.0 / Double(max(1, try await track.load(.nominalFrameRate)))
        guard abs(proxyRange.duration.seconds - timeRange.duration.seconds) <= frameSeconds + 0.0005 else {
            throw ProxyError.validationFailed("duration \(proxyRange.duration.seconds)s vs \(timeRange.duration.seconds)s")
        }

        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.moveItem(at: partial, to: destination)
        progress(1)
        return ProxyInfo(url: destination, frameCount: written, pixelWidth: Int(size.width), pixelHeight: Int(size.height))
    }

    /// The error a running job must stop with, if either side of the pipeline has failed.
    static func pipelineFailure(
        readerStatus: AVAssetReader.Status, readerError: (any Error)?,
        writerStatus: AVAssetWriter.Status, writerError: (any Error)?
    ) -> ProxyError? {
        if writerStatus == .failed { return .writeFailed(writerError?.localizedDescription ?? "unknown error") }
        if readerStatus == .failed { return .readFailed(readerError?.localizedDescription ?? "unknown error") }
        return nil
    }

    /// Counts frames without decoding them.
    static func frameCount(at url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ProxyError.noVideoTrack }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { throw ProxyError.readFailed(reader.error?.localizedDescription ?? "unknown") }
        // Blocking reads stay off the cooperative pool (see SampleCopyJob).
        let counter = FrameCountJob(reader: reader, output: output)
        return try await withCheckedThrowingContinuation { continuation in
            counter.queue.async { continuation.resume(with: counter.run()) }
        }
    }

    static func isFullRangeVideo(_ format: CMFormatDescription) -> Bool {
        CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_FullRangeVideo) as? Bool == true
    }

    /// AVFoundation requires all three color keys together. A source missing any of them stays untagged.
    private static func colorProperties(_ format: CMFormatDescription) -> [String: String]? {
        func value(_ key: CFString) -> String? { CMFormatDescriptionGetExtension(format, extensionKey: key) as? String }
        guard let primaries = value(kCMFormatDescriptionExtension_ColorPrimaries),
              let transfer = value(kCMFormatDescriptionExtension_TransferFunction),
              let matrix = value(kCMFormatDescriptionExtension_YCbCrMatrix) else { return nil }
        return [
            AVVideoColorPrimariesKey: primaries,
            AVVideoTransferFunctionKey: transfer,
            AVVideoYCbCrMatrixKey: matrix
        ]
    }
}

/// Runs one generation's copy/append loop on a private serial queue, pulled by
/// `requestMediaDataWhenReady(on:using:)`.
///
/// Confinement: the reader, output, writer, input, `continuation`, `progress` and `written` are touched
/// only on `queue` while the job runs. `cancelled` is the one cross-thread member. Once `finish` resumes
/// the continuation, the job never touches the writer again, so `generate` may use it afterwards.
private final class SampleCopyJob: @unchecked Sendable {
    let queue = DispatchQueue(label: "PerceptionEditor.ProxyGenerator.samples", qos: ProxyGenerator.workQoS)
    private let cancelled = Atomic<Bool>(false)
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let conversion: VideoRangeConversion?
    private let start: CMTime
    private let total: Double
    private let faults: ProxyGenerationFaults
    private var continuation: CheckedContinuation<Int, any Error>?
    private var progress: (@Sendable (Double) -> Void)?
    private var written = 0
    private var finished = false
    /// Rechecks reader and writer health while the job runs. If the writer fails while the input is not
    /// asking for data, AVFoundation never calls `pump` again and nothing else would end the job.
    private var watchdog: (any DispatchSourceTimer)?

    init(reader: AVAssetReader, output: AVAssetReaderTrackOutput, writer: AVAssetWriter,
         input: AVAssetWriterInput, conversion: VideoRangeConversion?,
         start: CMTime, total: Double, faults: ProxyGenerationFaults) {
        self.reader = reader
        self.output = output
        self.writer = writer
        self.input = input
        self.conversion = conversion
        self.start = start
        self.total = total
        self.faults = faults
    }

    /// Called once from `generate` before `begin` is dispatched; that `queue.async` orders this write before any queue access.
    func setProgress(_ progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
    }

    /// On `queue`.
    func begin(_ continuation: CheckedContinuation<Int, any Error>) {
        self.continuation = continuation
        if cancelled.load(ordering: .acquiring) { return finish(.failure(CancellationError())) }
        if let interval = faults.watchdogInterval {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + interval, repeating: interval)
            timer.setEventHandler { [weak self] in self?.failIfPipelineFailed() }
            timer.resume()
            watchdog = timer
        }
        input.requestMediaDataWhenReady(on: queue) { [self] in pump() }
    }

    /// Any thread. The flag stops a running pump at the next frame; the queued `finish` resumes promptly
    /// even while the input is not asking for data. If `begin` has not run yet, it sees the flag instead.
    func cancel() {
        cancelled.store(true, ordering: .releasing)
        queue.async { [self] in finish(.failure(CancellationError())) }
    }

    private var isCancelled: Bool { cancelled.load(ordering: .acquiring) }

    /// On `queue`.
    private func pump() {
        guard !finished, !isStalled else { return }
        while input.isReadyForMoreMediaData {
            if isCancelled { return finish(.failure(CancellationError())) }
            guard let sample = output.copyNextSampleBuffer() else {
                if isCancelled { return finish(.failure(CancellationError())) }
                if reader.status == .failed {
                    return finish(.failure(ProxyError.readFailed(reader.error?.localizedDescription ?? "unknown error")))
                }
                return finish(.success(written))
            }
            if isCancelled { return finish(.failure(CancellationError())) }
            let appended: Bool
            if let conversion {
                guard let converted = conversion.append(sample) else {
                    return finish(.failure(ProxyError.writeFailed("the video range conversion failed")))
                }
                appended = converted
            } else {
                appended = input.append(sample)
            }
            guard appended else {
                return finish(.failure(ProxyError.writeFailed(writer.error?.localizedDescription ?? "append failed")))
            }
            written += 1
            progress?(min(1, (sample.presentationTimeStamp - start).seconds / total))
            if isStalled { break }
        }
        // The input stopped asking for data. If that is because the writer (or reader) failed,
        // no further callback will come, so end the job now.
        failIfPipelineFailed()
    }

    /// On `queue`.
    private func failIfPipelineFailed() {
        guard !finished else { return }
        let failure = faults.pipelineFailure.map { $0() } ?? ProxyGenerator.pipelineFailure(
            readerStatus: reader.status, readerError: reader.error,
            writerStatus: writer.status, writerError: writer.error
        )
        if let failure { finish(.failure(failure)) }
    }

    /// Test fault: the input has (apparently) stopped asking for data.
    private var isStalled: Bool { faults.stallAfterFrames.map { written >= $0 } ?? false }

    /// On `queue`. Resumes the continuation at most once; later calls (a queued cancel after success,
    /// a late media-data callback) do nothing.
    private func finish(_ result: Result<Int, any Error>) {
        guard !finished, let continuation else { return }
        finished = true
        watchdog?.cancel()
        watchdog = nil
        self.continuation = nil
        progress = nil // Releases the caller's non-escaping closure before `generate` continues.
        switch result {
        case .success: input.markAsFinished()
        case .failure:
            reader.cancelReading()
            writer.cancelWriting()
        }
        continuation.resume(with: result)
    }
}

/// Converts full-range frames to correctly scaled video range (Y' 64…940, C 64…960) and appends them.
///
/// Confinement: used only on `SampleCopyJob.queue`.
private final class VideoRangeConversion: @unchecked Sendable {
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let session: VTPixelTransferSession

    init(input: AVAssetWriterInput, size: CGSize) throws {
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ])
        var created: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &created) == noErr, let created else {
            throw ProxyError.writeFailed("the video range converter could not be created")
        }
        session = created
    }

    deinit { VTPixelTransferSessionInvalidate(session) }

    /// The adaptor's result, or nil when the frame could not be converted.
    func append(_ sample: CMSampleBuffer) -> Bool? {
        guard let source = CMSampleBufferGetImageBuffer(sample), let pool = adaptor.pixelBufferPool else { return nil }
        var created: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created) == kCVReturnSuccess, let converted = created else { return nil }
        CVBufferPropagateAttachments(source, converted) // Color tags; the range lives in the pixel format.
        guard VTPixelTransferSessionTransferImage(session, from: source, to: converted) == noErr else { return nil }
        return adaptor.append(converted, withPresentationTime: sample.presentationTimeStamp)
    }
}

/// Confinement: `reader` and `output` are used only on `queue`, in `run`.
private final class FrameCountJob: @unchecked Sendable {
    let queue = DispatchQueue(label: "PerceptionEditor.ProxyGenerator.frameCount", qos: ProxyGenerator.workQoS)
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput

    init(reader: AVAssetReader, output: AVAssetReaderTrackOutput) {
        self.reader = reader
        self.output = output
    }

    func run() -> Result<Int, any Error> {
        var count = 0
        while let sample = output.copyNextSampleBuffer() { count += CMSampleBufferGetNumSamples(sample) }
        guard reader.status == .completed else {
            return .failure(ProxyError.readFailed(reader.error?.localizedDescription ?? "unknown"))
        }
        return .success(count)
    }
}
