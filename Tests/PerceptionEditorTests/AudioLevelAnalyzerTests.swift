@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import PerceptionEditor

/// Writes a mono sine WAV. `bursts` limits the tone to those time spans (seconds); the rest is silence.
/// `amplitude` is linear (1.0 = full scale). PCM cannot exceed full scale, so "hot" files use
/// amplitude 1.0 and a positive analysis gain.
private func writeToneWAVSync(
    to url: URL,
    seconds: Double,
    amplitude: Double,
    bitDepth: Int = 24,
    frequency: Double = 1000,
    sampleRate: Double = 48000,
    bursts: [ClosedRange<Double>]? = nil
) throws {
    let file = try AVAudioFile(forWriting: url, settings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: bitDepth,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false
    ])
    let format = file.processingFormat
    let chunk = 48000
    let total = Int(seconds * sampleRate)
    var written = 0
    while written < total {
        let count = min(chunk, total - written)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        let data = buffer.floatChannelData![0]
        for i in 0 ..< count {
            let t = Double(written + i) / sampleRate
            let on = bursts?.contains { $0.contains(t) } ?? true
            data[i] = on ? Float(amplitude * sin(2 * .pi * frequency * t)) : 0
        }
        try file.write(from: buffer)
        written += count
    }
}

/// Fixture writing is slow in debug builds; do it off the cooperative pool so parallel tests are not starved.
private func writeToneWAV(
    to url: URL,
    seconds: Double,
    amplitude: Double,
    bitDepth: Int = 24,
    frequency: Double = 1000,
    sampleRate: Double = 48000,
    bursts: [ClosedRange<Double>]? = nil
) async throws {
    try await Task.detached(priority: .utility) {
        try writeToneWAVSync(
            to: url, seconds: seconds, amplitude: amplitude, bitDepth: bitDepth,
            frequency: frequency, sampleRate: sampleRate, bursts: bursts
        )
    }.value
}

private func db(_ linear: Double) -> Double { 20 * log10(linear) }

@Suite struct AudioLevelAnalyzerTests {
    @Test func aQuietToneDoesNotClip() async throws {
        let dir = try TempDirectory()
        let url = dir.url.appendingPathComponent("quiet.wav")
        try await writeToneWAV(to: url, seconds: 1, amplitude: pow(10, -12 / 20))
        let levels = try await AudioLevelAnalyzer.analyze(url: url, range: nil, gainDecibels: 0)
        #expect(abs(levels.peakDecibels - -12) < 0.2)
        #expect(levels.clippedRanges.isEmpty)
    }

    @Test func aHotToneReportsItsClippedSpots() async throws {
        let dir = try TempDirectory()
        let url = dir.url.appendingPathComponent("hot.wav")
        try await writeToneWAV(to: url, seconds: 3, amplitude: 1.0, bursts: [0.5 ... 0.6, 2.0 ... 2.1])
        let levels = try await AudioLevelAnalyzer.analyze(url: url, range: nil, gainDecibels: 3)
        #expect(levels.peakDecibels > 2.9 && levels.peakDecibels < 3.1)
        #expect(levels.clippedRanges.count == 2)
        guard levels.clippedRanges.count == 2 else { return }
        // At +3 dB a 1 kHz sine is over full scale for ~half of each half-cycle, so the ranges start
        // and end within a cycle (1 ms) of the burst edges.
        #expect(abs(levels.clippedRanges[0].lowerBound - 0.5) < 0.001)
        #expect(abs(levels.clippedRanges[0].upperBound - 0.6) < 0.001)
        #expect(abs(levels.clippedRanges[1].lowerBound - 2.0) < 0.001)
        #expect(abs(levels.clippedRanges[1].upperBound - 2.1) < 0.001)
    }

    @Test func gainPushesAQuietToneIntoClipping() async throws {
        let dir = try TempDirectory()
        let url = dir.url.appendingPathComponent("six.wav")
        try await writeToneWAV(to: url, seconds: 1, amplitude: pow(10, -6 / 20))
        let flat = try await AudioLevelAnalyzer.analyze(url: url, range: nil, gainDecibels: 0)
        #expect(flat.clippedRanges.isEmpty)
        let boosted = try await AudioLevelAnalyzer.analyze(url: url, range: nil, gainDecibels: 12)
        #expect(boosted.peakDecibels > 5.9 && boosted.peakDecibels < 6.1)
        #expect(!boosted.clippedRanges.isEmpty)
    }

    @Test func silenceIsAtTheFloor() async throws {
        let dir = try TempDirectory()
        let url = dir.url.appendingPathComponent("silence.wav")
        try await writeToneWAV(to: url, seconds: 1, amplitude: 0)
        let levels = try await AudioLevelAnalyzer.analyze(url: url, range: nil, gainDecibels: 0)
        #expect(levels.peakDecibels == AudioLevelAnalyzer.floorDecibels)
        #expect(levels.peakDecibels.isFinite)
        #expect(levels.clippedRanges.isEmpty)
        let boosted = try await AudioLevelAnalyzer.analyze(url: url, range: nil, gainDecibels: 24)
        #expect(boosted.peakDecibels == AudioLevelAnalyzer.floorDecibels)
    }

    @Test func aFileWithNoAudioTrackThrowsNoAudio() async throws {
        let dir = try TempDirectory()
        let url = dir.url.appendingPathComponent("silent.mov")
        try await writeTestMovie(to: url, frames: 6, withAudio: false)
        await #expect(throws: AudioLevelError.noAudio) {
            try await AudioLevelAnalyzer.analyze(url: url, range: nil, gainDecibels: 0)
        }
    }

    @Test func twentyFourBitFilesDecodeToTheSameLevelsAs16Bit() async throws {
        let dir = try TempDirectory()
        let a = dir.url.appendingPathComponent("a16.wav")
        let b = dir.url.appendingPathComponent("a24.wav")
        try await writeToneWAV(to: a, seconds: 1, amplitude: 0.4, bitDepth: 16)
        try await writeToneWAV(to: b, seconds: 1, amplitude: 0.4, bitDepth: 24)
        let l16 = try await AudioLevelAnalyzer.analyze(url: a, range: nil, gainDecibels: 0)
        let l24 = try await AudioLevelAnalyzer.analyze(url: b, range: nil, gainDecibels: 0)
        #expect(abs(l16.peakDecibels - l24.peakDecibels) < 0.1)
        #expect(abs(l24.peakDecibels - db(0.4)) < 0.1)
    }

    @Test func aRangeOnlyReportsWhatIsInsideIt() async throws {
        let dir = try TempDirectory()
        let url = dir.url.appendingPathComponent("hot.wav")
        try await writeToneWAV(to: url, seconds: 3, amplitude: 1.0, bursts: [0.5 ... 0.6, 2.0 ... 2.1])
        let late = try await AudioLevelAnalyzer.analyze(url: url, range: 1.5 ... 2.5, gainDecibels: 3)
        #expect(late.clippedRanges.count == 1)
        if let only = late.clippedRanges.first {
            // File time, not range-relative.
            #expect(abs(only.lowerBound - 2.0) < 0.001)
        }
        let quietSpan = try await AudioLevelAnalyzer.analyze(url: url, range: 1.0 ... 1.5, gainDecibels: 3)
        #expect(quietSpan.clippedRanges.isEmpty)
        #expect(quietSpan.peakDecibels < -100)
    }

    @Test func cancellationStopsPromptly() async throws {
        let dir = try TempDirectory()
        let url = dir.url.appendingPathComponent("long.wav")
        try await writeToneWAV(to: url, seconds: 120, amplitude: 0.5)
        let task = Task { try await AudioLevelAnalyzer.analyze(url: url, range: nil, gainDecibels: 0) }
        try await Task.sleep(for: .milliseconds(30))
        let start = ContinuousClock.now
        task.cancel()
        _ = try? await task.value
        #expect(ContinuousClock.now - start < .seconds(1))
    }
}
