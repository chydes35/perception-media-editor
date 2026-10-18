@preconcurrency import AVFoundation
import Foundation
import MediaToolbox
import Testing
@testable import PerceptionEditor

private struct Unchecked<Value>: @unchecked Sendable { let value: Value }

/// Reads a player item's mixed audio through `AVAssetReaderAudioMixOutput` (the path export uses),
/// on a utility queue, and returns the peak of the mixed float output.
@MainActor
func mixedAudioPeak(_ item: AVPlayerItem, audioMix: AVAudioMix?) async throws -> Float {
    let tracks = try await item.asset.loadTracks(withMediaType: .audio)
    let reader = try AVAssetReader(asset: item.asset)
    let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false
    ])
    output.audioMix = audioMix
    reader.add(output)
    guard reader.startReading() else { throw AudioLevelError.readFailed }
    let box = Unchecked(value: (reader, output))
    return await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            var peak: Float = 0
            while let buffer = box.value.1.copyNextSampleBuffer() {
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                let length = CMBlockBufferGetDataLength(block)
                var data = [Float](repeating: 0, count: length / 4)
                _ = data.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
                }
                for value in data { peak = max(peak, abs(value)) }
            }
            continuation.resume(returning: peak)
        }
    }
}

@Suite struct AudioMeterStateTests {
    @Test func theClipLightLatchesUntilClickedOrPlaybackRestarts() {
        var meter = AudioMeterState()
        meter.update(peaks: (0.5, 0.5), isPlaying: true, elapsed: 1 / 30)
        #expect(!meter.clipped)
        meter.update(peaks: (1.0, 0.2), isPlaying: true, elapsed: 1 / 30)
        #expect(meter.clipped)
        for _ in 0 ..< 90 { meter.update(peaks: (0.1, 0.1), isPlaying: true, elapsed: 1 / 30) }
        #expect(meter.clipped, "Latched three seconds after the clip")
        meter.clearClip()
        #expect(!meter.clipped, "The user clicked it")

        meter.update(peaks: (0, 1.2), isPlaying: true, elapsed: 1 / 30)
        #expect(meter.clipped)
        meter.update(peaks: (0, 0), isPlaying: false, elapsed: 1 / 30)
        #expect(meter.clipped, "Pausing keeps it lit")
        meter.update(peaks: (0.1, 0.1), isPlaying: true, elapsed: 1 / 30)
        #expect(!meter.clipped, "Playback starting again clears it")
    }

    @Test func aPeakJustBelowFullScaleIsNotAClip() {
        var meter = AudioMeterState()
        meter.update(peaks: (Float(AudioLevelAnalyzer.clipThreshold) - 0.0001, 0), isPlaying: true, elapsed: 1 / 30)
        #expect(!meter.clipped)
    }

    @Test func theBarFallsAtTheDecayRateAndTheHoldWaits() {
        var meter = AudioMeterState()
        meter.update(peaks: (0.5, 0.25), isPlaying: true, elapsed: 1 / 30)
        #expect(abs(meter.levelDecibels.left - (-6.02)) < 0.01)
        #expect(abs(meter.levelDecibels.right - (-12.04)) < 0.01)
        meter.update(peaks: (0, 0), isPlaying: true, elapsed: 0.5)
        #expect(abs(meter.levelDecibels.left - (-6.02 - AudioMeterState.decayDecibelsPerSecond * 0.5)) < 0.01)
        #expect(abs(meter.holdDecibels.left - (-6.02)) < 0.01, "Hold stays for holdSeconds")
        meter.update(peaks: (0, 0), isPlaying: true, elapsed: 1.1)
        #expect(meter.holdDecibels.left < -6.03, "Then falls")
        for _ in 0 ..< 200 { meter.update(peaks: (0, 0), isPlaying: true, elapsed: 0.1) }
        #expect(meter.levelDecibels.left == AudioMeterState.floorDecibels)
        #expect(meter.holdDecibels.left == AudioMeterState.floorDecibels)
    }

    @Test func meterFractionCoversTheScale() {
        #expect(AudioMeterState.fraction(forDecibels: 0) == 1)
        #expect(AudioMeterState.fraction(forDecibels: 6) == 1)
        #expect(AudioMeterState.fraction(forDecibels: -60) == 0)
        #expect(AudioMeterState.fraction(forDecibels: -30) == 0.5)
        #expect(AudioMeterState.fraction(forDecibels: -.infinity) == 0)
    }

    @Test func theGainScheduleFollowsClipGainAndFades() {
        let schedule = MeterGainSchedule(segments: [
            .init(start: 0, end: 2, gain: 2, fadeIn: 1, fadeOut: 0),
            .init(start: 2, end: 4, gain: 0.5, fadeIn: 0, fadeOut: 1)
        ])
        #expect(schedule.gain(at: 0) == 0)
        #expect(schedule.gain(at: 0.5) == 1)
        #expect(schedule.gain(at: 1.5) == 2)
        #expect(schedule.gain(at: 2.5) == 0.5)
        #expect(abs(schedule.gain(at: 3.5) - 0.25) < 1e-9)
        #expect(schedule.gain(at: 5) == 0, "Past the end is silent")
        #expect(schedule.maximumGain(from: 1.9, to: 2.1) == 2, "A block across a cut takes the louder side")
        #expect(abs(schedule.maximumGain(from: 0.2, to: 0.4) - 0.8) < 1e-6, "Inside a fade: the block's loudest point")
    }
}

/// AVFoundation plumbing of the live meter, pulled through `AVAssetReaderAudioMixOutput`.
@MainActor
@Suite(.serialized)
struct AudioMeterPlumbingTests {
    private func toneClip(_ temp: TempDirectory, amplitude: Double = 0.25) async throws -> (TimelineClip, MediaAsset) {
        let url = try await writeTestMovie(to: temp.url.appendingPathComponent("tone.mov"), frames: 48, withAudio: true, toneAmplitude: amplitude)
        var asset = MediaAsset(url: url, kind: .video)
        asset.apply(await VideoMediaService.shared.metadata(for: url))
        return (TimelineClip(assetID: asset.id, frameRate: asset.frameRate ?? .ntsc23976, durationFrames: 48), asset)
    }

    /// The measurement behind the meter's gain math: a bare tap reads the source level while the
    /// mix's output carries the clip and master gain, so the tap sits before the mix volume.
    @Test func theTapSeesSamplesBeforeTheMixVolume() async throws {
        let temp = try TempDirectory()
        let (clip, asset) = try await toneClip(temp)
        for flags in [kMTAudioProcessingTapCreationFlag_PreEffects, kMTAudioProcessingTapCreationFlag_PostEffects] {
            let result = await TimelineCompositionService.shared.makePlayerItem(
                clips: [clip], media: [asset],
                audioAdjustmentsByClipID: [clip.id: ClipAudioAdjustments(gainDecibels: 6.0206)],
                quality: .preview, masterGainDecibels: 6.0206
            )
            let item = try #require(result.playerItem)
            let parameters = try #require(item.audioMix?.inputParameters.first?.mutableCopy() as? AVMutableAudioMixInputParameters)
            let tap = AudioMeterTap(schedule: nil)
            parameters.audioTapProcessor = tap.makeProcessingTap(flags: flags)
            let mix = AVMutableAudioMix()
            mix.inputParameters = [parameters]
            let mixed = try await mixedAudioPeak(item, audioMix: mix)
            let tapped = tap.takePeaks()
            #expect(tap.processedBlockCount > 0)
            #expect(abs(Double(tapped.left) - 0.25) < 0.01, "Tap reads the source: \(tapped.left)")
            #expect(abs(Double(mixed) - 1.0) < 0.02, "Mix output carries x4: \(mixed)")
        }
    }

    /// With `meters: true` the service's own tap applies the same gain, so the meter reads what is heard.
    @Test func theMeterTapReadsTheLevelAfterClipAndMasterGain() async throws {
        let temp = try TempDirectory()
        let (clip, asset) = try await toneClip(temp)
        let result = await TimelineCompositionService.shared.makePlayerItem(
            clips: [clip], media: [asset],
            audioAdjustmentsByClipID: [clip.id: ClipAudioAdjustments(gainDecibels: 6.0206)],
            quality: .preview, masterGainDecibels: -12.0412, meters: true
        )
        let item = try #require(result.playerItem)
        let tap = try #require(result.meterTap)
        let mixed = try await mixedAudioPeak(item, audioMix: item.audioMix)
        let tapped = tap.takePeaks()
        #expect(abs(Double(mixed) - 0.125) < 0.005, "x0.5 overall: \(mixed)")
        #expect(abs(Double(tapped.left) - Double(mixed)) < 0.005, "Meter \(tapped.left) matches the mix \(mixed)")
        #expect(tapped.left == tapped.right, "Mono source on both meters")
        let none = await TimelineCompositionService.shared.makePlayerItem(clips: [clip], media: [asset], quality: .preview)
        #expect(none.meterTap == nil, "No tap unless asked")
    }

    /// The tap also runs inside AVPlayer during playback (the live path). Needs an audio output device.
    @Test func theMeterTapRunsDuringPlayback() async throws {
        let temp = try TempDirectory()
        let (clip, asset) = try await toneClip(temp)
        let result = await TimelineCompositionService.shared.makePlayerItem(
            clips: [clip], media: [asset], quality: .preview, meters: true
        )
        let tap = try #require(result.meterTap)
        let player = AVPlayer(playerItem: try #require(result.playerItem))
        player.isMuted = false
        player.volume = 0.001
        player.play()
        defer { player.pause() }
        try await waitUntil(timeout: 10) { tap.processedBlockCount > 4 }
        let peaks = tap.takePeaks()
        #expect(peaks.left > 0.2 && peaks.left < 0.3, "Peak \(peaks.left) during playback")
    }
}
