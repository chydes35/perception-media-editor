@preconcurrency import AVFoundation
import Foundation
import VideoToolbox

enum TimelineExportPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case proRes422HQ = "ProRes 422 HQ"
    case hevcMain10 = "HEVC Main10"

    var id: String { rawValue }
}

enum TimelineExportSize: String, CaseIterable, Identifiable, Codable, Sendable {
    /// The timeline's own render size (the first clip's upright size).
    case timeline = "Timeline Size"
    case uhd = "UHD 3840 × 2160"
    case hd1080 = "1080p 1920 × 1080"

    var id: String { rawValue }

    /// The output size: the timeline scaled to fit inside the preset's frame, keeping its shape,
    /// with even sides for 4:2:2.
    func renderSize(for timeline: CGSize) -> CGSize {
        func even(_ size: CGSize) -> CGSize {
            CGSize(width: max(2, (size.width / 2).rounded() * 2), height: max(2, (size.height / 2).rounded() * 2))
        }
        let box: CGSize
        switch self {
        case .timeline: return even(timeline)
        case .uhd: box = CGSize(width: 3840, height: 2160)
        case .hd1080: box = CGSize(width: 1920, height: 1080)
        }
        guard timeline.width > 0, timeline.height > 0 else { return box }
        let scale = min(box.width / timeline.width, box.height / timeline.height)
        return even(CGSize(width: timeline.width * scale, height: timeline.height * scale))
    }
}

struct TimelineExportSettings: Equatable, Codable, Sendable {
    var preset: TimelineExportPreset = .proRes422HQ
    var size: TimelineExportSize = .timeline
}

/// Everything an export renders, captured from the project when it starts. There is no proxy
/// input: an export always reads the camera originals.
struct TimelineExportJob: Sendable {
    var clips: [TimelineClip]
    var media: [MediaAsset]
    var adjustmentsByClipID: [UUID: PhotoAdjustments] = [:]
    var audioAdjustmentsByClipID: [UUID: ClipAudioAdjustments] = [:]
    var sequenceFrameRate: FrameRate?
    var masterGainDecibels = 0.0
    var inputLUTsByAssetID: [UUID: ResolvedLUT] = [:]
    var ocioInputsByAssetID: [UUID: OCIOInputTransform] = [:]
}

struct TimelineExportResult: Sendable {
    var url: URL
    var frameCount: Int
    var renderSize: CGSize
    var seconds: Double
    var warnings: [String]
}

enum TimelineExportError: LocalizedError, Equatable {
    case alreadyExporting
    case nothingToExport(String)
    case insufficientSpace(neededBytes: Int64, availableBytes: Int64)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyExporting: "An export is already running."
        case .nothingToExport(let reason): reason
        case .insufficientSpace(let needed, let available):
            "The export needs about \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) free; " +
                "the destination has \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file))."
        case .failed(let reason): "The export failed: \(reason)"
        }
    }
}

/// Renders the timeline to a 10-bit movie: the composition at export quality, through the same
/// compositor and instructions as playback (video-range 10-bit 4:2:2 frames), into ProRes 422 HQ
/// or HEVC Main10, tagged Rec. 709, with the composition's mixed audio. The file is written as
/// `<name>.partial.mov` next to the destination and renamed into place only when complete, so a
/// failed or cancelled export leaves nothing behind. One export runs at a time.
actor TimelineExporter {
    static let shared = TimelineExporter()
    static let reserveBytes: Int64 = 1_024 * 1_024 * 1_024

    private let availableBytes: @Sendable (URL) -> Int64?
    private(set) var isExporting = false

    init(availableBytes: @escaping @Sendable (URL) -> Int64? = ProxyStore.availableBytes) {
        self.availableBytes = availableBytes
    }

    /// Bits per pixel per frame. ProRes 422 HQ is Apple's 707 Mb/s at UHD 23.976 (3.56); HEVC is
    /// the bitrate the exporter asks for.
    nonisolated static func bitsPerPixel(_ preset: TimelineExportPreset) -> Double {
        switch preset {
        case .proRes422HQ: 3.6
        case .hevcMain10: 0.25
        }
    }

    nonisolated static func estimatedBytes(preset: TimelineExportPreset, renderSize: CGSize, frames: Int, frameRate: FrameRate) -> Int64 {
        let video = renderSize.width * renderSize.height * Double(frames) * bitsPerPixel(preset) / 8 * 1.05
        let seconds = Double(frames) / frameRate.framesPerSecond
        let audio = seconds * (preset == .proRes422HQ ? 48_000 * 2 * 3 : 32_000)
        return Int64(video + audio)
    }

    func export(
        _ job: TimelineExportJob,
        settings: TimelineExportSettings,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> TimelineExportResult {
        guard !isExporting else { throw TimelineExportError.alreadyExporting }
        isExporting = true
        defer { isExporting = false }
        let started = Date()

        let originals = job.media.map(\.url)
        let resolved = destination.standardizedFileURL.resolvingSymlinksInPath()
        try ExportFileSafety.validate(resolved, protecting: originals)
        let folder = resolved.deletingLastPathComponent()
        let partial = folder.appendingPathComponent(resolved.deletingPathExtension().lastPathComponent + ".partial.mov")
        try ExportFileSafety.validate(partial, protecting: originals)

        let composed = await TimelineCompositionService.shared.makePlayerItem(
            clips: job.clips, media: job.media, adjustmentsByClipID: job.adjustmentsByClipID,
            audioAdjustmentsByClipID: job.audioAdjustmentsByClipID, quality: .export,
            sequenceFrameRate: job.sequenceFrameRate, masterGainDecibels: job.masterGainDecibels, renderingPath: .compositor, inputLUTsByAssetID: job.inputLUTsByAssetID,
            ocioInputsByAssetID: job.ocioInputsByAssetID
        )
        guard let item = composed.playerItem else {
            throw TimelineExportError.nothingToExport(composed.warnings.first ?? "The timeline has no clips to export.")
        }
        guard let base = item.videoComposition, let videoComposition = base.mutableCopy() as? AVMutableVideoComposition else {
            throw TimelineExportError.failed(composed.warnings.first ?? "the GPU compositor is unavailable")
        }
        let renderSize = settings.size.renderSize(for: base.renderSize)
        videoComposition.renderSize = renderSize
        let rate = job.sequenceFrameRate ?? job.clips.first?.frameRate ?? .ntsc23976
        let duration = try await item.asset.load(.duration)
        let frames = max(1, Int((duration.seconds * rate.framesPerSecond).rounded()))

        let needed = Self.estimatedBytes(preset: settings.preset, renderSize: renderSize, frames: frames, frameRate: rate) + Self.reserveBytes
        if let available = availableBytes(folder), available < needed {
            throw TimelineExportError.insufficientSpace(neededBytes: needed, availableBytes: available)
        }
        try Task.checkCancellation()

        // A leftover from an export that crashed; the name is this exporter's own.
        try? FileManager.default.removeItem(at: partial)
        do {
            let written = try await Self.transcode(
                asset: item.asset, videoComposition: videoComposition, audioMix: item.audioMix, settings: settings,
                renderSize: renderSize, rate: rate, frames: frames, to: partial, progress: progress
            )
            try Task.checkCancellation()
            // Recheck in case the destination was relinked to an original while rendering.
            try ExportFileSafety.validate(resolved, protecting: originals)
            guard rename(partial.path, resolved.path) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: resolved.path])
            }
            progress(1)
            return TimelineExportResult(
                url: resolved, frameCount: written, renderSize: renderSize,
                seconds: Date().timeIntervalSince(started), warnings: composed.warnings
            )
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    private nonisolated static func videoSettings(_ preset: TimelineExportPreset, size: CGSize, rate: FrameRate) -> [String: Any] {
        let color: [String: Any] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
        ]
        switch preset {
        case .proRes422HQ:
            return [
                AVVideoCodecKey: AVVideoCodecType.proRes422HQ,
                AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
                AVVideoColorPropertiesKey: color
            ]
        case .hevcMain10:
            let bitrate = max(2_000_000, size.width * size.height * rate.framesPerSecond * bitsPerPixel(.hevcMain10))
            return [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
                    AVVideoAverageBitRateKey: Int(bitrate),
                    AVVideoExpectedSourceFrameRateKey: rate.framesPerSecond,
                    AVVideoMaxKeyFrameIntervalKey: Int((rate.framesPerSecond * 2).rounded())
                ],
                AVVideoColorPropertiesKey: color
            ]
        }
    }

    /// The highest sample the exporter writes. The mix can reach about +48 dB (clip and master gain
    /// at +24 each) and its float output goes past full scale. 24-bit PCM saturates at full scale on its
    /// own. AAC encodes the overshoot instead (an HEVC export of a +48 dB tone decoded at +14.4 dBFS),
    /// and even a mix hard-clipped at 1.0 decodes at +0.44 dBFS (the codec's ringing on a square
    /// wave), so AAC is limited to -1 dBFS, which decoded at or under full scale.
    nonisolated static func audioCeiling(_ preset: TimelineExportPreset) -> Float {
        switch preset {
        case .proRes422HQ: 1
        case .hevcMain10: Float(pow(10, -1.0 / 20))
        }
    }

    /// Clamps a float32 PCM buffer to ±`ceiling` in place (NaN becomes silence). Hard clipping is the
    /// same saturation PCM does on its own; the Audio screen counts these spots before export.
    nonisolated static func limit(_ sample: CMSampleBuffer, to ceiling: Float) {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        let total = CMBlockBufferGetDataLength(block)
        var offset = 0
        while offset < total {
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(
                block, atOffset: offset, lengthAtOffsetOut: &length, totalLengthOut: nil, dataPointerOut: &pointer
            ) == kCMBlockBufferNoErr, let pointer, length > 0 else { return }
            let count = length / MemoryLayout<Float>.size
            pointer.withMemoryRebound(to: Float.self, capacity: count) { samples in
                for index in 0 ..< count {
                    let value = samples[index]
                    if value > ceiling { samples[index] = ceiling } else if value < -ceiling { samples[index] = -ceiling }
                    else if value.isNaN { samples[index] = 0 }
                }
            }
            offset += length
        }
    }

    private nonisolated static func audioSettings(_ preset: TimelineExportPreset) -> [String: Any] {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        let layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        switch preset {
        case .proRes422HQ:
            return [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false, AVChannelLayoutKey: layoutData
            ]
        case .hevcMain10:
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 256_000, AVChannelLayoutKey: layoutData
            ]
        }
    }

    /// Cancellation and completion shared by the two pump queues.
    private final class Pump: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelledFlag = false
        private var open: Int
        private var failure: String?
        private var continuation: CheckedContinuation<Void, Never>?
        var written = 0
        private var lastReported = -1

        init(inputs: Int) { open = inputs }

        var isCancelled: Bool { lock.withLock { cancelledFlag } }
        var failureReason: String? { lock.withLock { failure } }
        func cancel() { lock.withLock { cancelledFlag = true } }

        func wait() async {
            await withCheckedContinuation { continuation in
                let done = lock.withLock { () -> Bool in
                    if open == 0 { return true }
                    self.continuation = continuation
                    return false
                }
                if done { continuation.resume() }
            }
        }

        /// One input is done (or failed); the last one wakes the waiter.
        func finish(failure reason: String? = nil) {
            let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                if let reason, failure == nil { failure = reason }
                open -= 1
                guard open == 0 else { return nil }
                defer { continuation = nil }
                return continuation
            }
            waiter?.resume()
        }

        /// Whole-percent steps only, so observers are not woken for every frame.
        func shouldReport(_ fraction: Double) -> Bool {
            let percent = Int(fraction * 100)
            return lock.withLock {
                guard percent != lastReported else { return false }
                lastReported = percent
                return true
            }
        }
    }

    private struct Unchecked<Value>: @unchecked Sendable { let value: Value }

    /// AVFoundation's own message is often just "The operation could not be completed"; the
    /// underlying error says why.
    private nonisolated static func describe(_ error: Error?) -> String? {
        guard let error = error as NSError? else { return nil }
        var parts = [error.localizedDescription]
        if let reason = error.localizedFailureReason { parts.append(reason) }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("\(underlying.domain) \(underlying.code)")
        }
        parts.append("\(error.domain) \(error.code)")
        return parts.joined(separator: "; ")
    }

    private nonisolated static func transcode(
        asset: AVAsset, videoComposition: AVVideoComposition, audioMix: AVAudioMix?, settings: TimelineExportSettings,
        renderSize: CGSize, rate: FrameRate, frames: Int, to url: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Int {
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        // The composition always has an audio track; with only silent or muted clips it is empty,
        // and an audio-mix output over an empty track fails the whole read.
        var audioTracks: [AVAssetTrack] = []
        for track in try await asset.loadTracks(withMediaType: .audio) where try await !track.load(.segments).isEmpty {
            audioTracks.append(track)
        }
        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
        ])
        videoOutput.videoComposition = videoComposition
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)
        var audioOutput: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ])
            output.audioMix = audioMix
            // Each buffer is ours to change: the mix is limited to full scale in place before writing.
            output.alwaysCopiesSampleData = true
            reader.add(output)
            audioOutput = output
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieTimeScale = rate.timescale
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings(settings.preset, size: renderSize, rate: rate))
        videoInput.expectsMediaDataInRealTime = false
        videoInput.mediaTimeScale = rate.timescale
        writer.add(videoInput)
        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings(settings.preset))
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        }

        guard writer.startWriting() else { throw TimelineExportError.failed("starting the writer: " + (describe(writer.error) ?? "unknown error")) }
        guard reader.startReading() else {
            writer.cancelWriting()
            throw TimelineExportError.failed("reading the timeline: " + (describe(reader.error) ?? "the composition could not be read"))
        }
        writer.startSession(atSourceTime: .zero)

        let pump = Pump(inputs: audioInput == nil ? 1 : 2)
        let job = Unchecked(value: (reader: reader, video: (videoOutput, videoInput), audio: audioOutput.flatMap { o in audioInput.map { (o, $0) } }))
        let videoQueue = DispatchQueue(label: "PerceptionEditor.export.video", qos: .userInitiated)
        let audioQueue = DispatchQueue(label: "PerceptionEditor.export.audio", qos: .userInitiated)

        await withTaskCancellationHandler {
            let (videoOutput, videoInput) = job.value.video
            var videoDone = false
            videoInput.requestMediaDataWhenReady(on: videoQueue) {
                guard !videoDone else { return }
                while videoInput.isReadyForMoreMediaData {
                    if pump.isCancelled {
                        videoDone = true
                        videoInput.markAsFinished()
                        return pump.finish()
                    }
                    guard let sample = videoOutput.copyNextSampleBuffer() else {
                        videoDone = true
                        videoInput.markAsFinished()
                        return pump.finish()
                    }
                    guard videoInput.append(sample) else {
                        videoDone = true
                        return pump.finish(failure: "a video frame could not be written")
                    }
                    pump.written += 1
                    let fraction = min(0.999, Double(pump.written) / Double(frames))
                    if pump.shouldReport(fraction) { progress(fraction) }
                }
            }
            if let (audioOutput, audioInput) = job.value.audio {
                let ceiling = audioCeiling(settings.preset)
                var audioDone = false
                audioInput.requestMediaDataWhenReady(on: audioQueue) {
                    guard !audioDone else { return }
                    while audioInput.isReadyForMoreMediaData {
                        guard !pump.isCancelled, let sample = audioOutput.copyNextSampleBuffer() else {
                            audioDone = true
                            audioInput.markAsFinished()
                            return pump.finish()
                        }
                        limit(sample, to: ceiling)
                        guard audioInput.append(sample) else {
                            audioDone = true
                            return pump.finish(failure: "audio could not be written")
                        }
                    }
                }
            }
            await pump.wait()
        } onCancel: {
            // Only a flag: cancelling the reader while a pump queue is inside copyNextSampleBuffer
            // crashes in MediaToolbox. Each pump stops at its next sample.
            pump.cancel()
        }

        if pump.isCancelled || Task.isCancelled {
            reader.cancelReading()
            writer.cancelWriting()
            throw CancellationError()
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw TimelineExportError.failed("reading the timeline: " + (describe(reader.error) ?? "the composition could not be read"))
        }
        if let reason = pump.failureReason {
            let detail = describe(writer.error)
            writer.cancelWriting()
            throw TimelineExportError.failed(detail.map { "\(reason) (\($0))" } ?? reason)
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw TimelineExportError.failed("finishing the movie: " + (describe(writer.error) ?? "unknown error"))
        }
        return pump.written
    }
}
