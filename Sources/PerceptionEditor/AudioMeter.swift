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
    }

    var segments: [Segment]

    /// The gain at `seconds`; 0 outside every segment (a gap is silent in the mix too).
    func gain(at seconds: Double) -> Double {
        for segment in segments where seconds >= segment.start && seconds < segment.end {
            var gain = segment.gain
            if segment.fadeIn > 0, seconds < segment.start + segment.fadeIn {
                gain *= max(0, (seconds - segment.start) / segment.fadeIn)
            }
            if segment.fadeOut > 0, seconds > segment.end - segment.fadeOut {
                gain *= max(0, (segment.end - seconds) / segment.fadeOut)
            }
            return gain
        }
        return 0
    }

    /// The largest gain anywhere in `start ..< end` (a meter block), so a block straddling a cut or a
    /// fade never under-reads. Segment ends and fade edges are checked as well as the block's ends.
    /// Runs on the audio thread: no allocation.
    func maximumGain(from start: Double, to end: Double) -> Double {
        guard end > start else { return gain(at: start) }
        var best = 0.0
        for segment in segments where segment.end > start && segment.start < end {
            let lower = max(start, segment.start)
            let upper = min(end, segment.end)
            best = max(best, gain(at: lower), gain(at: upper - 1e-9))
            let fadeInEnd = segment.start + segment.fadeIn
            if fadeInEnd > lower, fadeInEnd < upper { best = max(best, gain(at: fadeInEnd)) }
            let fadeOutStart = segment.end - segment.fadeOut
            if fadeOutStart > lower, fadeOutStart < upper { best = max(best, gain(at: fadeOutStart)) }
        }
        return best
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
                let meter = Unmanaged<AudioMeterTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                meter.prepare(format.pointee)
            },
            unprepare: nil,
            process: { tap, frames, _, bufferList, framesOut, flagsOut in
                var range = CMTimeRange.zero
                let status = MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, &range, framesOut)
                guard status == noErr else { return }
                let meter = Unmanaged<AudioMeterTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                meter.process(bufferList, frames: framesOut.pointee, range: range)
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
        var peakL: Float = 0
        var peakR: Float = 0
        let channelCount = channels.load(ordering: .relaxed)
        if nonInterleaved.load(ordering: .relaxed) || buffers.count > 1 {
            for (index, buffer) in buffers.enumerated() {
                let peak = Self.peak(buffer, stride: 1, offset: 0)
                if index == 0 { peakL = peak } else if index == 1 { peakR = peak } else { peakR = max(peakR, peak) }
            }
            if buffers.count == 1 { peakR = peakL }
        } else if let buffer = buffers.first {
            let stride = max(1, Int(buffer.mNumberChannels) > 0 ? Int(buffer.mNumberChannels) : channelCount)
            peakL = Self.peak(buffer, stride: stride, offset: 0)
            peakR = stride > 1 ? Self.peak(buffer, stride: stride, offset: 1) : peakL
        }

        if let schedule {
            let start = range.start.seconds
            let rate = Double(bitPattern: sampleRate.load(ordering: .relaxed))
            let duration = range.duration.seconds.isFinite && range.duration.seconds > 0
                ? range.duration.seconds : Double(frames) / rate
            let gain = start.isFinite ? Float(schedule.maximumGain(from: start, to: start + duration)) : 1
            peakL *= gain
            peakR *= gain
        }
        Self.raise(left, to: peakL)
        Self.raise(right, to: peakR)
    }

    private static func peak(_ buffer: AudioBuffer, stride: Int, offset: Int) -> Float {
        guard let data = buffer.mData else { return 0 }
        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        let samples = data.assumingMemoryBound(to: Float.self)
        var peak: Float = 0
        var index = offset
        while index < count {
            let magnitude = abs(samples[index])
            if magnitude > peak { peak = magnitude }
            index += stride
        }
        return peak.isFinite ? peak : 0
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
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self else { return }
                self.tick(elapsed: interval)
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
