@preconcurrency import AVFoundation
import Foundation
import Metal
import Testing
@testable import PerceptionEditor

@MainActor
@Suite(.serialized, .enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct TimelineExporterTests {
    private func job(_ clips: [TimelineClip], _ media: [MediaAsset], adjustments: [UUID: PhotoAdjustments] = [:]) -> TimelineExportJob {
        TimelineExportJob(clips: clips, media: media, adjustmentsByClipID: adjustments)
    }

    private func frameNumbered(_ temp: TempDirectory, frames: Int = 240) async throws -> MediaAsset {
        let url = try await writeFrameNumberedMovie(to: temp.url.appendingPathComponent("numbers.mov"), frames: frames)
        return MediaAsset(url: url, kind: .video, durationSeconds: Double(frames) / 23.976, frameRate: .ntsc23976, frameCount: Int64(frames))
    }

    private func videoTrackFormat(_ url: URL) async throws -> CMFormatDescription {
        let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
        return try #require(try await track.load(.formatDescriptions).first)
    }

    private func frameCount(_ url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        #expect(reader.startReading())
        let box = Unchecked(value: output)
        return await Task.detached {
            var count = 0
            while let sample = box.value.copyNextSampleBuffer() { if CMSampleBufferGetNumSamples(sample) > 0 { count += 1 } }
            return count
        }.value
    }

    @Test func exportKeepsEveryFrameExactlyAcrossCuts() async throws {
        let temp = try TempDirectory()
        let asset = try await frameNumbered(temp)
        // Source 10…59, then source 100…149, then 200…219.
        let clips = [
            TimelineClip(assetID: asset.id, timelineStartFrame: 0, sourceStartFrame: 10, durationFrames: 50),
            TimelineClip(assetID: asset.id, timelineStartFrame: 50, sourceStartFrame: 100, durationFrames: 50),
            TimelineClip(assetID: asset.id, timelineStartFrame: 100, sourceStartFrame: 200, durationFrames: 20)
        ]
        let destination = temp.url.appendingPathComponent("Cut.mov")
        let result = try await TimelineExporter().export(
            job(clips, [asset]), settings: TimelineExportSettings(preset: .proRes422HQ, size: .timeline), to: destination
        )
        #expect(result.frameCount == 120)
        #expect(try await frameCount(destination) == 120, "Frame count is the sum of the clip durations")
        let shown = try await shownFrameNumbers(AVPlayerItem(url: destination), frames: 120)
        let expected = Array(10 ..< 60) + Array(100 ..< 150) + Array(200 ..< 220)
        #expect(shown == expected, "Exported frame k must be source frame k of its clip")
        #expect(!FileManager.default.fileExists(atPath: temp.url.appendingPathComponent("Cut.partial.mov").path))
    }

    /// Video-range 10-bit keeps codes 64…940, so a full 0…1023 ramp can keep at most 877 levels; an
    /// 8-bit path would keep about 220.
    @Test func proResExportIsTenBit() async throws {
        let temp = try TempDirectory()
        guard let ramp = try await writeFullRangeTestMovie(to: temp.url.appendingPathComponent("ramp.mov"), frames: 6, width: 1280, height: 72) else {
            Issue.record("This Mac cannot write the 10-bit HEVC fixture")
            return
        }
        var asset = MediaAsset(url: ramp, kind: .video)
        asset.apply(await VideoMediaService.shared.metadata(for: ramp))
        let clip = TimelineClip(assetID: asset.id, frameRate: asset.frameRate ?? .ntsc23976, durationFrames: 6)
        let destination = temp.url.appendingPathComponent("Ramp export.mov")
        _ = try await TimelineExporter().export(job([clip], [asset]), settings: TimelineExportSettings(preset: .proRes422HQ, size: .timeline), to: destination)

        let format = try await videoTrackFormat(destination)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_AppleProRes422HQ)
        let levels = try await distinctLumaLevels(destination)
        print("ProRes export: \(levels) distinct luma levels on the ramp")
        #expect(levels >= 860, "Only \(levels) of 877 video-range levels survived")
    }

    @Test func hevcExportIsMain10() async throws {
        let temp = try TempDirectory()
        guard let ramp = try await writeFullRangeTestMovie(to: temp.url.appendingPathComponent("ramp.mov"), frames: 6, width: 1280, height: 72) else {
            Issue.record("This Mac cannot write the 10-bit HEVC fixture")
            return
        }
        var asset = MediaAsset(url: ramp, kind: .video)
        asset.apply(await VideoMediaService.shared.metadata(for: ramp))
        let clip = TimelineClip(assetID: asset.id, frameRate: asset.frameRate ?? .ntsc23976, durationFrames: 6)
        let destination = temp.url.appendingPathComponent("Ramp HEVC.mov")
        _ = try await TimelineExporter().export(job([clip], [asset]), settings: TimelineExportSettings(preset: .hevcMain10, size: .timeline), to: destination)

        let format = try await videoTrackFormat(destination)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC)
        let levels = try await distinctLumaLevels(destination)
        print("HEVC Main10 export: \(levels) distinct luma levels on the ramp")
        #expect(levels >= 700, "Only \(levels) distinct levels: not a 10-bit encode")
        let primaries = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String
        #expect(primaries == kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String)
    }

    @Test func sizePresetsFitTheTimelineInside() {
        #expect(TimelineExportSize.uhd.renderSize(for: CGSize(width: 1920, height: 1080)) == CGSize(width: 3840, height: 2160))
        #expect(TimelineExportSize.hd1080.renderSize(for: CGSize(width: 3840, height: 2160)) == CGSize(width: 1920, height: 1080))
        // A 4:3 timeline keeps its shape, with even sizes for 4:2:2.
        #expect(TimelineExportSize.hd1080.renderSize(for: CGSize(width: 1440, height: 1080)) == CGSize(width: 1440, height: 1080))
        #expect(TimelineExportSize.hd1080.renderSize(for: CGSize(width: 2160, height: 3840)) == CGSize(width: 608, height: 1080))
        #expect(TimelineExportSize.timeline.renderSize(for: CGSize(width: 161, height: 91)) == CGSize(width: 162, height: 92))
    }

    @Test func exportScalesToTheChosenSize() async throws {
        let temp = try TempDirectory()
        let asset = try await frameNumbered(temp, frames: 24)
        let clip = TimelineClip(assetID: asset.id, durationFrames: 12)
        let destination = temp.url.appendingPathComponent("HD.mov")
        _ = try await TimelineExporter().export(job([clip], [asset]), settings: TimelineExportSettings(preset: .proRes422HQ, size: .hd1080), to: destination)
        let dimensions = CMVideoFormatDescriptionGetDimensions(try await videoTrackFormat(destination))
        #expect(dimensions.width == 1920 && dimensions.height == 1080)
        #expect(try await shownFrameNumbers(AVPlayerItem(url: destination), frames: 12) == Array(0 ..< 12))
    }

    @Test func audioIsCarriedThrough() async throws {
        let temp = try TempDirectory()
        let url = try await writeTestMovie(to: temp.url.appendingPathComponent("audio.mov"), frames: 24, withAudio: true)
        var asset = MediaAsset(url: url, kind: .video)
        asset.apply(await VideoMediaService.shared.metadata(for: url))
        let clip = TimelineClip(assetID: asset.id, frameRate: asset.frameRate ?? .ntsc23976, durationFrames: 24)
        for preset in TimelineExportPreset.allCases {
            let destination = temp.url.appendingPathComponent("Audio \(preset.rawValue).mov")
            _ = try await TimelineExporter().export(job([clip], [asset]), settings: TimelineExportSettings(preset: preset, size: .timeline), to: destination)
            let audio = try await AVURLAsset(url: destination).loadTracks(withMediaType: .audio)
            #expect(audio.count == 1, "\(preset) export has its audio")
            let format = try #require(try await audio.first?.load(.formatDescriptions).first)
            let subtype = CMFormatDescriptionGetMediaSubType(format)
            #expect(subtype == (preset == .proRes422HQ ? kAudioFormatLinearPCM : kAudioFormatMPEG4AAC))
        }
    }

    /// Decoded export audio as float (first channel), read on a utility queue.
    private func decodedAudio(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 2
        ])
        reader.add(output)
        #expect(reader.startReading())
        let box = Unchecked(value: (reader, output))
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var samples: [Float] = []
                while let buffer = box.value.1.copyNextSampleBuffer() {
                    guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                    let length = CMBlockBufferGetDataLength(block)
                    var data = [Float](repeating: 0, count: length / 4)
                    _ = data.withUnsafeMutableBytes {
                        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
                    }
                    for frame in stride(from: 0, to: data.count, by: 2) { samples.append(data[frame]) }
                }
                continuation.resume(returning: samples)
            }
        }
    }

    /// Clip +24 dB and master +24 dB (about 251x) on a -6 dBFS tone: the export must saturate at
    /// full scale (a square-ish wave with the tone's signs), never wrap or turn into garbage.
    @Test func extremeGainSaturatesTheExportInsteadOfWrapping() async throws {
        let temp = try TempDirectory()
        let url = try await writeTestMovie(to: temp.url.appendingPathComponent("tone.mov"), frames: 48, withAudio: true, toneAmplitude: 0.5)
        var asset = MediaAsset(url: url, kind: .video)
        asset.apply(await VideoMediaService.shared.metadata(for: url))
        let clip = TimelineClip(assetID: asset.id, frameRate: asset.frameRate ?? .ntsc23976, durationFrames: 48)
        for preset in TimelineExportPreset.allCases {
            var hot = job([clip], [asset])
            hot.audioAdjustmentsByClipID = [clip.id: ClipAudioAdjustments(gainDecibels: 24)]
            hot.masterGainDecibels = 24
            let destination = temp.url.appendingPathComponent("Hot \(preset.rawValue).mov")
            _ = try await TimelineExporter().export(hot, settings: TimelineExportSettings(preset: preset, size: .timeline), to: destination)
            let samples = try await decodedAudio(destination)
            #expect(samples.count > 48_000, "\(preset): \(samples.count) samples")
            let peak = samples.map { abs($0) }.max() ?? 0
            // Skip the first and last 10 ms (codec edges); compare signs where the tone is clearly
            // away from zero. A wrapped integer or garbage would flip them.
            var flips = 0
            var checked = 0
            var nearFull = 0
            for index in 480 ..< max(480, samples.count - 480) {
                let tone = sin(2 * Double.pi * 1000 * Double(index) / 48_000)
                guard abs(tone) > 0.3 else { continue }
                checked += 1
                if (samples[index] > 0) != (tone > 0) { flips += 1 }
                if abs(samples[index]) > 0.75 { nearFull += 1 }
            }
            print("Hot export \(preset): peak \(peak) (\(AudioLevelAnalyzer.decibels(forLinearPeak: Double(peak))) dBFS), sign flips \(flips)/\(checked), near full scale \(nearFull)")
            #expect(peak <= 1.0, "\(preset): peak \(peak) is over full scale")
            #expect(flips == 0, "\(preset): \(flips) of \(checked) samples have the wrong sign")
            #expect(Double(nearFull) > 0.9 * Double(checked), "\(preset): saturated, not quiet or garbage")
        }
    }

    @Test func cancellingLeavesNoFiles() async throws {
        let temp = try TempDirectory()
        let asset = try await frameNumbered(temp, frames: 240)
        let clip = TimelineClip(assetID: asset.id, durationFrames: 240)
        let destination = temp.url.appendingPathComponent("Cancelled.mov")
        let exporter = TimelineExporter()
        let started = Flag()
        let task = Task {
            try await exporter.export(job([clip], [asset]), settings: TimelineExportSettings(preset: .proRes422HQ, size: .uhd), to: destination) { fraction in
                if fraction > 0 { started.set() }
            }
        }
        try await waitUntil { started.isSet }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let left = try FileManager.default.contentsOfDirectory(atPath: temp.url.path)
        #expect(!left.contains("Cancelled.mov") && !left.contains("Cancelled.partial.mov"), "Left behind: \(left)")
        #expect(await exporter.isExporting == false)
    }

    @Test func onlyOneExportRunsAtATime() async throws {
        let temp = try TempDirectory()
        let asset = try await frameNumbered(temp, frames: 240)
        let clip = TimelineClip(assetID: asset.id, durationFrames: 240)
        let exporter = TimelineExporter()
        let started = Flag()
        let first = Task {
            try await exporter.export(job([clip], [asset]), settings: TimelineExportSettings(preset: .proRes422HQ, size: .uhd),
                                      to: temp.url.appendingPathComponent("First.mov")) { _ in started.set() }
        }
        try await waitUntil { started.isSet }
        await #expect(throws: TimelineExportError.alreadyExporting) {
            try await exporter.export(job([clip], [asset]), settings: TimelineExportSettings(preset: .proRes422HQ, size: .timeline),
                                      to: temp.url.appendingPathComponent("Second.mov"))
        }
        first.cancel()
        _ = try? await first.value
    }

    @Test func anOriginalIsNeverTheDestination() async throws {
        let temp = try TempDirectory()
        let asset = try await frameNumbered(temp, frames: 24)
        let before = try Data(contentsOf: asset.url)
        let clip = TimelineClip(assetID: asset.id, durationFrames: 12)
        await #expect(throws: ExportFileError.self) {
            try await TimelineExporter().export(job([clip], [asset]), settings: TimelineExportSettings(preset: .proRes422HQ, size: .timeline), to: asset.url)
        }
        #expect(try Data(contentsOf: asset.url) == before, "The original is untouched")
    }

    @Test func aFullDiskIsRefusedBeforeWriting() async throws {
        let temp = try TempDirectory()
        let asset = try await frameNumbered(temp, frames: 24)
        let clip = TimelineClip(assetID: asset.id, durationFrames: 24)
        let destination = temp.url.appendingPathComponent("Full.mov")
        let exporter = TimelineExporter(availableBytes: { _ in 10_000 })
        await #expect {
            try await exporter.export(job([clip], [asset]), settings: TimelineExportSettings(preset: .proRes422HQ, size: .uhd), to: destination)
        } throws: { error in
            if case TimelineExportError.insufficientSpace = error { return true }
            return false
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func estimatesScaleWithSizeAndCodec() {
        let uhd = TimelineExporter.estimatedBytes(preset: .proRes422HQ, renderSize: CGSize(width: 3840, height: 2160), frames: 24 * 60, frameRate: .ntsc23976)
        let hd = TimelineExporter.estimatedBytes(preset: .proRes422HQ, renderSize: CGSize(width: 1920, height: 1080), frames: 24 * 60, frameRate: .ntsc23976)
        let hevc = TimelineExporter.estimatedBytes(preset: .hevcMain10, renderSize: CGSize(width: 3840, height: 2160), frames: 24 * 60, frameRate: .ntsc23976)
        // Apple's figure for UHD 23.976 ProRes 422 HQ is 707 Mb/s: about 5.3 GB a minute.
        #expect(uhd > 5_000_000_000 && uhd < 6_500_000_000)
        #expect(hd < uhd / 3 && hevc < uhd / 5)
    }

    /// Distinct 10-bit luma codes along the middle row of the first frame, read back as `x422`.
    private func distinctLumaLevels(_ url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
        ])
        reader.add(output)
        #expect(reader.startReading())
        let sample = try #require(output.copyNextSampleBuffer())
        reader.cancelReading()
        let buffer = try #require(CMSampleBufferGetImageBuffer(sample))
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(to: UInt16.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) / 2
        let row = CVPixelBufferGetHeightOfPlane(buffer, 0) / 2
        return Set((0 ..< CVPixelBufferGetWidthOfPlane(buffer, 0)).map { base[row * stride + $0] >> 6 }).count
    }

    private struct Unchecked<Value>: @unchecked Sendable { let value: Value }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }
}

@MainActor
@Suite(.serialized, .enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct TimelineExportStoreTests {
    private func makeStore(_ temp: TempDirectory) throws -> EditorStore {
        let suite = "pme-export-tests-\(UUID().uuidString)"
        return EditorStore(
            presetRepository: UserPresetRepository(defaults: UserDefaults(suiteName: suite)!),
            proxyStore: ProxyStore(directory: try temp.subdirectory("Proxy Cache"), availableBytes: { _ in 1 << 40 }),
            proxyDefaults: UserDefaults(suiteName: suite)!,
            lutLibrary: LUTLibrary(directory: temp.url.appendingPathComponent("Library")),
            timelineExporter: TimelineExporter(availableBytes: { _ in 1 << 40 })
        )
    }

    @Test func theStoreExportsTheTimelineAndPausesProxiesMeanwhile() async throws {
        let temp = try TempDirectory()
        let store = try makeStore(temp)
        let url = try await writeFrameNumberedMovie(to: temp.url.appendingPathComponent("numbers.mov"), frames: 48)
        let asset = MediaAsset(url: url, kind: .video, durationSeconds: 2, frameRate: .ntsc23976, frameCount: 48)
        store.project.media = [asset]
        store.project.timelineClips = [TimelineClip(assetID: asset.id, durationFrames: 48)]
        store.timelineExportSettings = TimelineExportSettings(preset: .proRes422HQ, size: .uhd)

        let destination = temp.url.appendingPathComponent("Timeline.mov")
        let task = try store.startTimelineExport(to: destination)
        #expect(store.timelineExport.isRunning)
        #expect(store.proxyStore.isPaused, "No proxy is generated while exporting")
        #expect(throws: TimelineExportError.alreadyExporting) { try store.startTimelineExport(to: temp.url.appendingPathComponent("Other.mov")) }
        await task.value
        #expect(store.timelineExport.phase == .finished(destination.standardizedFileURL.resolvingSymlinksInPath()))
        #expect(!store.proxyStore.isPaused)
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func cancellingFromTheStore() async throws {
        let temp = try TempDirectory()
        let store = try makeStore(temp)
        let url = try await writeFrameNumberedMovie(to: temp.url.appendingPathComponent("numbers.mov"), frames: 240)
        let asset = MediaAsset(url: url, kind: .video, durationSeconds: 10, frameRate: .ntsc23976, frameCount: 240)
        store.project.media = [asset]
        store.project.timelineClips = [TimelineClip(assetID: asset.id, durationFrames: 240)]
        store.timelineExportSettings = TimelineExportSettings(preset: .proRes422HQ, size: .uhd)
        let task = try store.startTimelineExport(to: temp.url.appendingPathComponent("Stopped.mov"))
        try await waitUntil { store.timelineExport.fraction > 0 }
        store.cancelTimelineExport()
        await task.value
        #expect(store.timelineExport.phase == .cancelled)
        #expect(!store.proxyStore.isPaused)
        let left = try FileManager.default.contentsOfDirectory(atPath: temp.url.path)
        #expect(!left.contains { $0.hasPrefix("Stopped") }, "Left behind: \(left)")
    }
}

@MainActor
struct ProxyPauseTests {
    @Test func aPausedStoreGeneratesNothingUntilResumed() async throws {
        let temp = try TempDirectory()
        let store = ProxyStore(directory: try temp.subdirectory("Proxy Cache"), availableBytes: { _ in 1 << 40 })
        let url = try await writeTestMovie(to: temp.url.appendingPathComponent("clip.mov"), frames: 24)
        let asset = MediaAsset(url: url, kind: .video, durationSeconds: 1)
        store.pause()
        store.enqueue([asset])
        try await Task.sleep(for: .milliseconds(300))
        #expect(store.statuses[asset.id] == .queued && store.activeJobs == 0)
        store.resume()
        guard case .ready = try await waitForProxy(store, asset.id) else {
            Issue.record("The proxy did not finish after resume")
            return
        }
    }
}
