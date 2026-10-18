@preconcurrency import AVFoundation
import Combine
import Foundation
import MediaToolbox
import Synchronization

/// Linear gain over composition time for the meter: clip gain times master gain, with the same
/// fade ramps the audio mix applies. Built once per preview composition and never mutated, so the
/// audio thread reads it without locks.
struct MeterGainSchedule: Sendable, Equatable {
    struct Segment: Sendable, Equatable {
        var start: Double
        var end: Double
        var gain: Double
        var fadeIn: Double
        var fadeOut: Double

        /// This segment's gain at `seconds` (fades included), ignoring every other segment.
        func gain(at seconds: Double) -> Double {
            guard seconds >= start, seconds < end else { return 0 }
            var value = gain
            if fadeIn > 0, seconds < start + fadeIn { value *= max(0, (seconds - start) / fadeIn) }
            if fadeOut > 0, seconds > end - fadeOut { value *= max(0, (end - seconds) / fadeOut) }
            return value
        }

        /// The largest gain of this segment within `from ..< to` (clamped to the segment): its ends
        /// and fade edges. Never another clip's gain. Runs on the audio thread: no allocation.
        func maximumGain(from lowerBound: Double, to upperBound: Double) -> Double {
            let lower = max(lowerBound, start)
            let upper = min(upperBound, end)
            guard upper > lower else { return gain(at: lower) }
            var best = max(gain(at: lower), gain(at: upper - 1e-9))
            let fadeInEnd = start + fadeIn
            if fadeInEnd > lower, fadeInEnd < upper { best = max(best, gain(at: fadeInEnd)) }
            let fadeOutStart = end - fadeOut
            if fadeOutStart > lower, fadeOutStart < upper { best = max(best, gain(at: fadeOutStart)) }
            return best
        }
    }

    var segments: [Segment]

    /// The gain at `seconds`; 0 outside every segment (a gap is silent in the mix too).
    func gain(at seconds: Double) -> Double {
        for segment in segments where seconds >= segment.start && seconds < segment.end {
            return segment.gain(at: seconds)
        }
        return 0
    }
}

/// Live peak metering for the preview player. An `MTAudioProcessingTap` on the preview composition's
/// audio track sees every block the player renders; the process callback measures the block's peak per
/// channel and folds it into two lock-free atomics (float bits; non-negative floats order like their
/// bits, so an integer max is a float max). It never allocates, locks or waits. The UI reads and
/// resets the peaks at its own rate with `takePeaks()`.
///
/// Measured on macOS 26 (`AudioMeterPlumbingTests`): the tap sees samples BEFORE the audio mix's
/// volume and ramps, so the clip and master gain are applied here from `MeterGainSchedule`, and the
/// meter shows what will be heard and exported.
final class AudioMeterTap: @unchecked Sendable {
    private let left = Atomic<UInt32>(0)
    private let right = Atomic<UInt32>(0)
    private let blocks = Atomic<Int>(0)
    private let channels = Atomic<Int>(2)
    private let nonInterleaved = Atomic<Bool>(true)
    private let sampleRate = Atomic<UInt64>(48_000.0.bitPattern)
    /// Immutable after init: read on the audio thread without synchronization.
    let schedule: MeterGainSchedule?

    init(schedule: MeterGainSchedule?) {
        self.schedule = schedule
    }

    /// How many blocks the tap has processed. A test seam.
    var processedBlockCount: Int { blocks.load(ordering: .relaxed) }

    /// The highest linear peak per channel since the last call, then resets both to zero.
    func takePeaks() -> (left: Float, right: Float) {
        let l = Float(bitPattern: left.exchange(0, ordering: .relaxed))
        let r = Float(bitPattern: right.exchange(0, ordering: .relaxed))
        return (l, r)
    }

    /// Creates the processing tap for one `AVMutableAudioMixInputParameters`. The tap retains this
    /// object until AVFoundation finalizes it.
    func makeProcessingTap(flags: MTAudioProcessingTapCreationFlags = kMTAudioProcessingTapCreationFlag_PostEffects) -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(self).toOpaque(),
            init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
            finalize: { tap in
                Unmanaged<AudioMeterTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                Unmanaged<AudioMeterTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    ._withUnsafeGuaranteedRef { $0.prepare(format.pointee) }
            },
            unprepare: nil,
            process: { tap, frames, _, bufferList, framesOut, flagsOut in
                var range = CMTimeRange.zero
                let status = MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, &range, framesOut)
                guard status == noErr else { return }
                // The tap's storage keeps the meter alive, so no retain/release on the audio thread.
                Unmanaged<AudioMeterTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    ._withUnsafeGuaranteedRef { $0.process(bufferList, frames: framesOut.pointee, range: range) }
            }
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &callbacks, flags, &tap
        )
        guard status == noErr, let tap else {
            Unmanaged.passUnretained(self).release()
            return nil
        }
        return tap
    }

    private func prepare(_ format: AudioStreamBasicDescription) {
        channels.store(max(1, Int(format.mChannelsPerFrame)), ordering: .relaxed)
        nonInterleaved.store(format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0, ordering: .relaxed)
        if format.mSampleRate > 0 { sampleRate.store(format.mSampleRate.bitPattern, ordering: .relaxed) }
    }

    /// Audio thread. Float32 PCM is the tap's processing format.
    private func process(_ list: UnsafeMutablePointer<AudioBufferList>, frames: CMItemCount, range: CMTimeRange) {
        blocks.add(1, ordering: .relaxed)
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let rate = Double(bitPattern: sampleRate.load(ordering: .relaxed))
        let start = range.start.seconds
        let blockStart = start.isFinite ? start : .nan
        let schedule = blockStart.isFinite ? schedule : nil
        var peakL: Float = 0
        var peakR: Float = 0
        if nonInterleaved.load(ordering: .relaxed) || buffers.count > 1 {
            for (index, buffer) in buffers.enumerated() {
                guard let data = buffer.mData else { continue }
                let count = min(Int(frames), Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
                let peak = Self.scaledPeak(
                    data.assumingMemoryBound(to: Float.self), frames: count, stride: 1, offset: 0,
                    blockStart: blockStart, sampleRate: rate, schedule: schedule
                )
                if index == 0 { peakL = peak } else if index == 1 { peakR = peak } else { peakR = max(peakR, peak) }
            }
            if buffers.count == 1 { peakR = peakL }
        } else if let buffer = buffers.first, let data = buffer.mData {
            let channelCount = channels.load(ordering: .relaxed)
            let stride = max(1, Int(buffer.mNumberChannels) > 0 ? Int(buffer.mNumberChannels) : channelCount)
            let count = min(Int(frames), Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / stride)
            let samples = data.assumingMemoryBound(to: Float.self)
            peakL = Self.scaledPeak(samples, frames: count, stride: stride, offset: 0, blockStart: blockStart, sampleRate: rate, schedule: schedule)
            peakR = stride > 1
                ? Self.scaledPeak(samples, frames: count, stride: stride, offset: 1, blockStart: blockStart, sampleRate: rate, schedule: schedule)
                : peakL
        }
        Self.raise(left, to: peakL)
        Self.raise(right, to: peakR)
    }

    /// The peak of one channel (`samples[frame * stride + offset]`) after the mix's gain. A block can
    /// straddle a cut between clips of different gain, so it is split at segment boundaries (frame
    /// index from the block's start time and the sample rate) and each part's peak is scaled by that
    /// part's own gain (its loudest point, fades included). Frames in no segment are a silent gap.
    /// Runs on the audio thread: no allocation.
    static func scaledPeak(
        _ samples: UnsafePointer<Float>, frames: Int, stride: Int, offset: Int,
        blockStart: Double, sampleRate: Double, schedule: MeterGainSchedule?
    ) -> Float {
        func rawPeak(_ first: Int, _ end: Int) -> Float {
            var peak: Float = 0
            var frame = first
            while frame < end {
                let magnitude = abs(samples[frame * stride + offset])
                if magnitude > peak { peak = magnitude }
                frame += 1
            }
            return peak.isFinite ? peak : 0
        }
        guard frames > 0 else { return 0 }
        guard let schedule, blockStart.isFinite, sampleRate > 0 else { return rawPeak(0, frames) }
        // The first frame at or after a boundary; the small allowance keeps a boundary that is
        // exactly on a frame (but computed a hair late in floating point) on that frame.
        func frame(at seconds: Double) -> Int {
            max(0, min(frames, Int(((seconds - blockStart) * sampleRate - 1e-6).rounded(.up))))
        }
        var peak: Float = 0
        for segment in schedule.segments {
            let first = frame(at: segment.start)
            let end = frame(at: segment.end)
            guard first < end else { continue }
            let gain = segment.maximumGain(
                from: blockStart + Double(first) / sampleRate,
                to: blockStart + Double(end) / sampleRate
            )
            peak = max(peak, rawPeak(first, end) * Float(gain))
        }
        return peak
    }

    /// Lock-free max: retries only while another writer raised the value in between.
    private static func raise(_ atomic: borrowing Atomic<UInt32>, to value: Float) {
        guard value > 0, value.isFinite else { return }
        let bits = value.bitPattern
        var current = atomic.load(ordering: .relaxed)
        while bits > current {
            let (exchanged, original) = atomic.compareExchange(expected: current, desired: bits, ordering: .relaxed)
            if exchanged { return }
            current = original
        }
    }
}

/// What the meters show: per-channel level with a falling bar, a peak hold, and a clip light that
/// latches until the user clears it or playback starts again. Pure value logic, driven at a fixed
/// rate by `AudioMeterModel`.
struct AudioMeterState: Equatable, Sendable {
    /// Bottom of the meter scale.
    static let floorDecibels = -60.0
    /// The bar falls this fast after a peak.
    static let decayDecibelsPerSecond = 24.0
    /// The hold line stays this long, then falls at the decay rate.
    static let holdSeconds = 1.5

    var levelDecibels = (left: floorDecibels, right: floorDecibels)
    var holdDecibels = (left: floorDecibels, right: floorDecibels)
    private var holdAge = (left: 0.0, right: 0.0)
    private(set) var clipped = false
    private var wasPlaying = false

    static func == (a: Self, b: Self) -> Bool {
        a.levelDecibels == b.levelDecibels && a.holdDecibels == b.holdDecibels && a.clipped == b.clipped
            && a.holdAge == b.holdAge && a.wasPlaying == b.wasPlaying
    }

    /// One meter tick: `peaks` are the linear peaks since the last tick (after gain).
    mutating func update(peaks: (left: Float, right: Float), isPlaying: Bool, elapsed: Double) {
        if isPlaying, !wasPlaying { clipped = false }
        wasPlaying = isPlaying
        let step = max(0, elapsed)
        if Double(max(peaks.left, peaks.right)) >= AudioLevelAnalyzer.clipThreshold { clipped = true }

        func advance(level: inout Double, hold: inout Double, age: inout Double, peak: Float) {
            let incoming = max(Self.floorDecibels, AudioLevelAnalyzer.decibels(forLinearPeak: Double(peak)))
            level = max(incoming, level - Self.decayDecibelsPerSecond * step)
            level = max(Self.floorDecibels, level)
            if incoming >= hold {
                hold = incoming
                age = 0
            } else {
                age += step
                if age > Self.holdSeconds {
                    hold = max(level, hold - Self.decayDecibelsPerSecond * step)
                }
            }
        }
        advance(level: &levelDecibels.left, hold: &holdDecibels.left, age: &holdAge.left, peak: peaks.left)
        advance(level: &levelDecibels.right, hold: &holdDecibels.right, age: &holdAge.right, peak: peaks.right)
    }

    /// The user clicked the clip light.
    mutating func clearClip() { clipped = false }

    /// The bar's fill, 0…1, for a level in dBFS on the meter scale.
    static func fraction(forDecibels decibels: Double) -> Double {
        guard decibels.isFinite else { return 0 }
        return min(1, max(0, (decibels - floorDecibels) / -floorDecibels))
    }
}

/// Publishes the meters at `rate` while running. Kept out of `EditorStore` so meter ticks redraw only the meters.
@MainActor
final class AudioMeterModel: ObservableObject {
    static let rate = 30.0

    @Published private(set) var state = AudioMeterState()
    private var task: Task<Void, Never>?
    private var tap: AudioMeterTap?
    private var isPlaying: @MainActor () -> Bool = { false }

    var isRunning: Bool { task != nil }

    /// The tap of the current preview build, or nil when there is none.
    func attach(_ tap: AudioMeterTap?) {
        self.tap = tap
        _ = tap?.takePeaks()
    }

    func start(isPlaying: @escaping @MainActor () -> Bool) {
        self.isPlaying = isPlaying
        guard task == nil else { return }
        let interval = 1 / Self.rate
        task = Task { @MainActor [weak self] in
            // Main-actor sleeps run late under load; decay and hold use the real time between ticks.
            let clock = ContinuousClock()
            var last = clock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self else { return }
                let now = clock.now
                let elapsed = now - last
                last = now
                self.tick(elapsed: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        state = AudioMeterState()
    }

    func clearClip() { state.clearClip() }

    func tick(elapsed: Double) {
        let playing = isPlaying()
        let peaks = tap?.takePeaks() ?? (0, 0)
        var next = state
        next.update(peaks: playing ? peaks : (0, 0), isPlaying: playing, elapsed: elapsed)
        if next != state { state = next }
    }
}
