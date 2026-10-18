@preconcurrency import AVFoundation
import Foundation

/// Peak level and clipped spots of an audio file, after gain. Times are in seconds of file time.
struct AudioLevels: Equatable, Sendable {
    /// Highest absolute sample after gain, in dBFS. `AudioLevelAnalyzer.floorDecibels` for silence.
    var peakDecibels: Double
    /// Spans where samples reached `AudioLevelAnalyzer.clipThreshold` or more after gain.
    var clippedRanges: [ClosedRange<Double>]
}

enum AudioLevelError: Error, Equatable {
    /// The file has no audio track.
    case noAudio
    /// The reader could not start or failed while reading.
    case readFailed
}

enum AudioLevelAnalyzer {
    /// Reported for digital silence (and anything below it), so callers never see -infinity or NaN.
    static let floorDecibels: Double = -160

    /// A sample is clipped when `abs(sample * gain) >= clipThreshold`. Integer PCM tops out one step below
    /// 1.0 (the largest 16-bit code, 32767, decodes to exactly 1 - 2^-15; 24-bit full scale is 1 - 2^-23),
    /// so a literal `>= 1.0` would never flag a hard-clipped recording at 0 dB gain. The threshold is one
    /// 16-bit step below full scale: it flags 16-bit and 24-bit full-scale codes, and stays above any
    /// normal peak (-0.1 dBFS is 0.9886).
    static let clipThreshold: Double = 1 - 1.0 / 32768

    /// Clipped samples closer together than this are merged into one range.
    static let mergeGap: Double = 0.002

    /// Streams the file's first audio track through `AVAssetReader` as 32-bit float PCM, one decoded
    /// buffer at a time (memory stays bounded by the buffer size, never the file length), and reports
    /// the peak and the clipped spots after `gainDecibels`. A sample is clipped when
    /// `abs(sample * gain) >= clipThreshold` on any channel; clipped samples within `mergeGap` (2 ms) of each other form one range.
    ///
    /// With `range`, only samples inside it count, and reported times are still file time (not relative
    /// to `range.lowerBound`). Runs off the calling actor, reads the file read-only, and stops promptly
    /// on cancellation by throwing `CancellationError`. Throws `AudioLevelError.noAudio` without an audio track.
    /// `range` is clamped to the file's duration; a range wholly outside it gives the floor and no ranges.
    ///
    /// Time of a sample is its buffer's presentation timestamp plus its index in the buffer over the
    /// sample rate, not a running sample count from zero: that is exact for PCM and stays right for
    /// compressed audio with priming or edit lists. Many concurrent analyses are the caller's to serialize.
    ///
    /// `didReadBuffer` is a test seam called on the scan queue after each decoded buffer.
    static func analyze(
        url: URL,
        range: ClosedRange<Double>?,
        gainDecibels: Double,
        didReadBuffer: (@Sendable () -> Void)? = nil
    ) async throws -> AudioLevels {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw AudioLevelError.noAudio }
        try Task.checkCancellation()

        var effectiveRange = range
        if let requested = range {
            let duration = try await asset.load(.duration).seconds
            if duration.isFinite {
                let lower = max(0, requested.lowerBound)
                let upper = min(duration, requested.upperBound)
                guard lower <= upper, lower < duration else {
                    return AudioLevels(peakDecibels: floorDecibels, clippedRanges: [])
                }
                effectiveRange = lower ... upper
            }
        }

        // The read blocks on the decoder, so it runs on a dispatch queue rather than a cooperative
        // thread: blocking calls on the Swift concurrency pool can starve unrelated async work.
        let clampedRange = effectiveRange
        let job = ScanJob(asset: asset, track: track, didReadBuffer: didReadBuffer)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result {
                        try scan(job: job, range: clampedRange, gainDecibels: gainDecibels)
                    })
                }
            }
        } onCancel: {
            job.cancel()
        }
    }

    private final class ScanJob: @unchecked Sendable {
        let asset: AVURLAsset
        let track: AVAssetTrack
        let didReadBuffer: (@Sendable () -> Void)?
        private let lock = NSLock()
        private var cancelled = false

        init(asset: AVURLAsset, track: AVAssetTrack, didReadBuffer: (@Sendable () -> Void)?) {
            self.asset = asset
            self.track = track
            self.didReadBuffer = didReadBuffer
        }

        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }

    static func decibels(forLinearPeak peak: Double) -> Double {
        guard peak.isFinite, peak > 0 else { return floorDecibels }
        return max(floorDecibels, 20 * log10(peak))
    }

    private static func scan(job: ScanJob, range: ClosedRange<Double>?, gainDecibels: Double) throws -> AudioLevels {
        let reader = try AVAssetReader(asset: job.asset)
        let output = AVAssetReaderTrackOutput(track: job.track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AudioLevelError.readFailed }
        reader.add(output)
        if let range {
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: range.lowerBound, preferredTimescale: 48000),
                end: CMTime(seconds: range.upperBound, preferredTimescale: 48000)
            )
        }
        guard reader.startReading() else {
            reader.cancelReading()
            throw AudioLevelError.readFailed
        }

        let gain = pow(10, gainDecibels / 20)
        var peak = 0.0
        var ranges: [ClosedRange<Double>] = []
        var openStart: Double?
        var openEnd = 0.0
        var scratch: [Float] = []

        while true {
            if job.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            guard let buffer = output.copyNextSampleBuffer() else { break }
            job.didReadBuffer?()
            guard let format = CMSampleBufferGetFormatDescription(buffer),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                  let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let channels = max(1, Int(asbd.mChannelsPerFrame))
            let rate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48000
            let frames = CMSampleBufferGetNumSamples(buffer)
            let length = CMBlockBufferGetDataLength(block)
            let floatCount = min(frames * channels, length / MemoryLayout<Float>.size)
            guard floatCount > 0 else { continue }
            let start = CMSampleBufferGetPresentationTimeStamp(buffer).seconds

            if scratch.count < floatCount { scratch = [Float](repeating: 0, count: floatCount) }
            let status = scratch.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(
                    block, atOffset: 0, dataLength: floatCount * MemoryLayout<Float>.size,
                    destination: $0.baseAddress!
                )
            }
            guard status == kCMBlockBufferNoErr else {
                reader.cancelReading()
                throw AudioLevelError.readFailed
            }

            for frame in 0 ..< floatCount / channels {
                let time = start + Double(frame) / rate
                if let range, !range.contains(time) { continue }
                var framePeak: Float = 0
                for channel in 0 ..< channels {
                    let magnitude = abs(scratch[frame * channels + channel])
                    if magnitude > framePeak { framePeak = magnitude }
                }
                let scaled = Double(framePeak) * gain
                if scaled > peak { peak = scaled }
                if scaled >= clipThreshold {
                    if openStart != nil, time - openEnd <= mergeGap {
                        openEnd = time
                    } else {
                        if let begin = openStart { ranges.append(begin ... openEnd) }
                        openStart = time
                        openEnd = time
                    }
                }
            }
        }
        if job.isCancelled || reader.status == .cancelled { throw CancellationError() }
        if reader.status == .failed { throw AudioLevelError.readFailed }
        if let begin = openStart { ranges.append(begin ... openEnd) }
        return AudioLevels(peakDecibels: decibels(forLinearPeak: peak), clippedRanges: ranges)
    }
}
