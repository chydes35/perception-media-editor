@preconcurrency import AVFoundation
import CoreImage
import Foundation
import ImageIO
import Metal
import Testing
@testable import PerceptionEditor

/// The custom compositor, driven the way AVFoundation drives it: through `AVAssetReader`,
/// `AVAssetImageGenerator` and `AVPlayer`. Without a Metal device these are reported as skipped.
@MainActor
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct TimelineVideoCompositorTests {
    private let service = TimelineCompositionService.shared

    // MARK: Helpers

    private struct Unchecked<Value>: @unchecked Sendable { let value: Value }

    /// Runs blocking work on a background queue so it never occupies the main actor or the cooperative pool.
    private func offMain<Result>(_ work: @escaping @Sendable () async throws -> Result) async throws -> Result {
        let boxed: Unchecked<Result> = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                Task.detached {
                    do { continuation.resume(returning: Unchecked(value: try await work())) } catch { continuation.resume(throwing: error) }
                }
            }
        }
        return boxed.value
    }

    private func compose(
        _ clips: [TimelineClip],
        _ media: [MediaAsset],
        adjustments: [UUID: PhotoAdjustments] = [:],
        quality: MediaQuality = .preview,
        proxies: [UUID: URL] = [:],
        path: TimelineRenderingPath = .compositor,
        statisticsKey: UUID? = nil
    ) async throws -> (item: AVPlayerItem, result: TimelineCompositionResult) {
        let result = await service.makePlayerItem(
            clips: clips, media: media, adjustmentsByClipID: adjustments, quality: quality,
            proxyURLsByAssetID: proxies, renderingPath: path, statisticsKey: statisticsKey
        )
        return (try #require(result.playerItem), result)
    }

    /// Reads every frame of an item off the main actor: the reader blocks until the compositor has
    /// answered, and a blocked main thread would starve every other main-actor test.
    private func allSamples(_ item: AVPlayerItem, pixelFormat: OSType) async throws -> [(buffer: CVPixelBuffer, start: CMTime)] {
        let tracks = Unchecked(value: try await item.asset.loadTracks(withMediaType: .video))
        let job = Unchecked(value: (asset: item.asset, composition: item.videoComposition))
        return try await offMain {
            let reader = try AVAssetReader(asset: job.value.asset)
            let output = AVAssetReaderVideoCompositionOutput(
                videoTracks: tracks.value, videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
            )
            output.videoComposition = job.value.composition
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
            var frames: [(CVPixelBuffer, CMTime)] = []
            while let sample = output.copyNextSampleBuffer() {
                if let buffer = CMSampleBufferGetImageBuffer(sample) { frames.append((buffer, sample.presentationTimeStamp)) }
            }
            if reader.status != .completed { throw reader.error ?? CocoaError(.fileReadUnknown) }
            return frames
        }.map { ($0.0, $0.1) }
    }

    private func allFrames(_ item: AVPlayerItem, pixelFormat: OSType) async throws -> [CVPixelBuffer] {
        try await allSamples(item, pixelFormat: pixelFormat).map(\.buffer)
    }

    private func halfPixels(_ buffer: CVPixelBuffer, row: Int) -> [SIMD3<Float>] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.advanced(by: row * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: Float16.self)
        return (0 ..< width).map { SIMD3(Float(base[$0 * 4]), Float(base[$0 * 4 + 1]), Float(base[$0 * 4 + 2])) }
    }

    /// The source's own first frame, decoded without any composition (`xf22`, what the compositor receives).
    private func sourceFirstFrame(_ url: URL) async throws -> CVPixelBuffer {
        try await offMain {
            let asset = AVURLAsset(url: url)
            let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_422YpCbCr10BiPlanarFullRange
            ])
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
            let sample = try #require(output.copyNextSampleBuffer())
            reader.cancelReading()
            return try #require(CMSampleBufferGetImageBuffer(sample))
        }
    }

    /// The first row of a frame decoded by the color kernel alone. Synchronous because it waits on the GPU.
    private func referenceRow(decoding source: CVPixelBuffer) async throws -> [SIMD3<Float>] {
        let source = Unchecked(value: source)
        return try await offMain { try Self.decodeRow(source.value) }
    }

    private nonisolated static func decodeRow(_ source: CVPixelBuffer) throws -> [SIMD3<Float>] {
        let kernels = try VideoColorKernels()
        let width = CVPixelBufferGetWidth(source)
        let texture = try kernels.makeWorkingTexture(width: width, height: CVPixelBufferGetHeight(source))
        let commandBuffer = try #require(kernels.runtime.queue.makeCommandBuffer())
        try kernels.decode(source, matrix: .rec709, into: texture, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return Array(MetalColorKernelTests.readPixels(texture).prefix(width))
    }

    private func image(from item: AVPlayerItem, at time: CMTime) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.videoComposition = item.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: time).image
    }

    /// 8-bit RGBA of an image drawn into a bitmap in Apple's Rec. 709 video space, the one AVFoundation
    /// decodes 709-tagged video into, so a comparison sees code values, not conversions.
    private func rec709Bytes(_ image: CGImage) throws -> (width: Int, height: Int, bytes: [UInt8]) {
        let space = try #require(CGColorSpace(name: CGColorSpace.coreMedia709))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(
            data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (image.width, image.height, bytes)
    }

    private func goldenImage(_ name: String) throws -> CGImage {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/video/\(name).png")
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil), "Missing golden frame \(url.path)")
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func difference(_ a: CGImage, _ b: CGImage) throws -> (mean: Double, max: Int) {
        let (wa, ha, bytesA) = try rec709Bytes(a), (wb, hb, bytesB) = try rec709Bytes(b)
        try #require(wa == wb && ha == hb, "Sizes differ: \(wa)×\(ha) vs \(wb)×\(hb)")
        var total = 0, worst = 0, count = 0
        for i in stride(from: 0, to: bytesA.count, by: 4) {
            for c in 0 ..< 3 {
                let d = abs(Int(bytesA[i + c]) - Int(bytesB[i + c]))
                total += d; worst = max(worst, d); count += 1
            }
        }
        return (Double(total) / Double(count), worst)
    }

    private func patternAsset(_ temp: TempDirectory, name: String = "pattern", frames: Int = 12, codec: AVVideoCodecType = .proRes422,
                              width: Int = 192, height: Int = 108, transform: CGAffineTransform = .identity) async throws -> MediaAsset {
        let url = try await writeColorPatternMovie(to: temp.url.appendingPathComponent("\(name).mov"), codec: codec, frames: frames,
                                                   width: width, height: height, transform: transform)
        return MediaAsset(url: url, kind: .video, durationSeconds: Double(frames) * 1001 / 24000, frameRate: .ntsc23976, frameCount: Int64(frames))
    }

    private func numberedAsset(_ temp: TempDirectory, name: String = "numbers", frames: Int = 240) async throws -> MediaAsset {
        let url = try await writeFrameNumberedMovie(to: temp.url.appendingPathComponent("\(name).mov"), frames: frames)
        return MediaAsset(url: url, kind: .video, durationSeconds: Double(frames) * 1001 / 24000, frameRate: .ntsc23976, frameCount: Int64(frames))
    }

    private func fullRangeAsset(_ temp: TempDirectory, width: Int = 1024, height: Int = 64, frames: Int = 6, isLog: Bool = true) async throws -> MediaAsset? {
        guard let url = try await writeFullRangeTestMovie(to: temp.url.appendingPathComponent("vlog-\(width).mov"), frames: frames, width: width, height: height) else {
            return nil
        }
        var asset = MediaAsset(url: url, kind: .video, durationSeconds: Double(frames) * 1001 / 24000, frameRate: .ntsc23976, frameCount: Int64(frames))
        asset.sourceColor = SourceColorDescriptor(
            bitDepth: 10, chroma: .yuv422, range: .full, matrix: .rec709,
            transfer: isLog ? .vLog : .rec709, gamut: isLog ? .vGamut : .rec709, detectedFrom: .panasonicMetadata
        )
        return asset
    }

    // MARK: Which path a composition takes

    @Test func plainRec709ClipsKeepTheNativePlaybackPath() async throws {
        let temp = try TempDirectory()
        let asset = try await patternAsset(temp)
        let clip = TimelineClip(assetID: asset.id, durationFrames: 12)
        let (item, _) = try await compose([clip], [asset], path: .automatic)
        #expect(item.videoComposition == nil, "A neutral, unproxied Rec. 709 clip needs no compositor")
    }

    @Test func gradingLogFootageAndProxiesEngageTheCompositor() async throws {
        let temp = try TempDirectory()
        let asset = try await patternAsset(temp)
        let clip = TimelineClip(assetID: asset.id, durationFrames: 12)

        let graded = try await compose([clip], [asset], adjustments: [clip.id: PhotoAdjustments(exposure: 0.3)], path: .automatic)
        #expect(graded.item.videoComposition?.customVideoCompositorClass != nil)

        if let log = try await fullRangeAsset(temp, width: 128, height: 64) {
            let logClip = TimelineClip(assetID: log.id, durationFrames: 6)
            let flagged = try await compose([logClip], [log], path: .automatic)
            #expect(flagged.item.videoComposition?.customVideoCompositorClass != nil, "V-Log needs the compositor for its input transform")
        }

        let proxy = try await ProxyGenerator.generate(
            source: asset.url, destination: temp.url.appendingPathComponent("p.mov"), maximumSize: CGSize(width: 96, height: 54)
        ).url
        let proxied = try await compose([clip], [asset], proxies: [asset.id: proxy], path: .automatic)
        #expect(proxied.item.videoComposition?.renderSize == CGSize(width: 96, height: 54))
    }

    @Test func previewAndExportRenderInTheirOwnFormats() async throws {
        let temp = try TempDirectory()
        let asset = try await patternAsset(temp)
        let clip = TimelineClip(assetID: asset.id, durationFrames: 12)
        let preview = try await compose([clip], [asset], quality: .preview)
        let export = try await compose([clip], [asset], quality: .export)
        #expect(preview.item.videoComposition?.customVideoCompositorClass === PreviewVideoCompositor.self)
        #expect(export.item.videoComposition?.customVideoCompositorClass === ExportVideoCompositor.self)
        #expect(PreviewVideoCompositor.outputPixelFormat == kCVPixelFormatType_64RGBAHalf)
        #expect(ExportVideoCompositor.outputPixelFormat == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)
    }

    // MARK: 10-bit precision

    @Test func neutralTenBitFootageKeepsEveryLevelThroughThePreviewPath() async throws {
        let temp = try TempDirectory()
        guard let asset = try await fullRangeAsset(temp) else { Issue.record("No full-range 10-bit HEVC encoder"); return }
        let clip = TimelineClip(assetID: asset.id, durationFrames: 6)
        let (item, _) = try await compose([clip], [asset], quality: .preview)

        let frames = try await allFrames(item, pixelFormat: kCVPixelFormatType_64RGBAHalf)
        #expect(frames.count == 6)
        let output = halfPixels(try #require(frames.first), row: 0)

        // Reference: the same frame decoded by the Task 3 kernel (verified against the equations).
        let reference = try await referenceRow(decoding: try await sourceFirstFrame(asset.url))

        #expect(output == reference, "A neutral clip must come out exactly as decoded: no 8-bit stage anywhere")
        let levels = Set(output.map(\.x)).count
        print("Distinct red levels across a 1024-column ramp after the compositor: \(levels)")
        #expect(levels >= 900, "Only \(levels) distinct levels survived")
    }

    @Test func exportOutputIsTenBitVideoRangeOfTheSameValues() async throws {
        let temp = try TempDirectory()
        guard let asset = try await fullRangeAsset(temp) else { Issue.record("No full-range 10-bit HEVC encoder"); return }
        let clip = TimelineClip(assetID: asset.id, durationFrames: 6)
        let (item, _) = try await compose([clip], [asset], quality: .export)
        let frames = try await allFrames(item, pixelFormat: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)
        let output = try #require(frames.first)
        #expect(CVPixelBufferGetPixelFormatType(output) == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)

        let source = try await sourceFirstFrame(asset.url)
        CVPixelBufferLockBaseAddress(source, .readOnly); CVPixelBufferLockBaseAddress(output, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly); CVPixelBufferUnlockBaseAddress(output, .readOnly) }
        let sourceLuma = try #require(CVPixelBufferGetBaseAddressOfPlane(source, 0)).assumingMemoryBound(to: UInt16.self)
        let outputLuma = try #require(CVPixelBufferGetBaseAddressOfPlane(output, 0)).assumingMemoryBound(to: UInt16.self)
        let sourceStride = CVPixelBufferGetBytesPerRowOfPlane(source, 0) / 2, outputStride = CVPixelBufferGetBytesPerRowOfPlane(output, 0) / 2
        var worst = 0.0
        for x in 0 ..< CVPixelBufferGetWidth(source) {
            let code = Double(sourceLuma[10 * sourceStride + x] >> 6)
            let expected = 64 + 876 * code / 1023
            worst = max(worst, abs(Double(outputLuma[10 * outputStride + x] >> 6) - expected))
        }
        #expect(worst <= 1.0, "Full-range code values map onto 64…940 within \(worst) codes")
    }

    // MARK: Look

    @Test func gradedFrameMatchesTheOldCoreImagePath() async throws {
        let temp = try TempDirectory()
        let asset = try await patternAsset(temp)
        let clip = TimelineClip(assetID: asset.id, durationFrames: 12)
        let (item, result) = try await compose([clip], [asset], adjustments: [clip.id: goldenGradeAdjustments()])
        #expect(result.warnings.isEmpty)
        let shown = try await image(from: item, at: CMTime(value: 3 * 1001, timescale: 24000))
        let drift = try difference(shown, try goldenImage("old-ci-path-graded"))
        print("Graded vs old CIFilter path: mean \(drift.mean) / 255, max \(drift.max) / 255")
        // Measured: mean 0.31, max 16 of 255. The largest differences are on the sharp wedge edges of the
        // aggressive HSL setting, where an 8-bit and a half-float input are amplified. Tagging the frames with
        // plain ITU-R 709 instead of CoreMedia709 measured a mean of 10.
        #expect(drift.mean <= 0.6 && drift.max <= 24, "Mean \(drift.mean), max \(drift.max) of 255")
    }

    @Test func neutralFrameMatchesAVFoundationsOwnDecode() async throws {
        let temp = try TempDirectory()
        let asset = try await patternAsset(temp)
        let clip = TimelineClip(assetID: asset.id, durationFrames: 12)
        let (item, _) = try await compose([clip], [asset])
        let shown = try await image(from: item, at: CMTime(value: 3 * 1001, timescale: 24000))
        let drift = try difference(shown, try goldenImage("old-ci-path-neutral"))
        print("Neutral vs AVFoundation decode: mean \(drift.mean) / 255, max \(drift.max) / 255")
        #expect(drift.mean <= 0.3 && drift.max <= 4, "Mean \(drift.mean), max \(drift.max) of 255")
    }

    // MARK: Geometry

    @Test func aRotatedClipComesOutUpright() async throws {
        let temp = try TempDirectory()
        // Stored 192×108 and tagged to display rotated a quarter turn clockwise: 108×192 on screen.
        let rotate = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 108, ty: 0)
        let asset = try await patternAsset(temp, transform: rotate)
        let clip = TimelineClip(assetID: asset.id, durationFrames: 12)
        let (item, _) = try await compose([clip], [asset])
        #expect(item.videoComposition?.renderSize == CGSize(width: 108, height: 192))

        let shown = try await image(from: item, at: .zero)
        let (width, height, bytes) = try rec709Bytes(shown)
        #expect(width == 108 && height == 192)
        // Screen (X, Y) shows source (x, y) = (Y, 108 − X) scaled: red grows downward, green grows to the left.
        var worst = 0.0
        for X in [30, 60, 85] {
            for Y in [30, 90, 150] {
                let expected = colorPatternRGB(u: (Double(Y) + 0.5) / 192, v: 1 - (Double(X) + 0.5) / 108)
                let i = (Y * width + X) * 4
                worst = max(worst, abs(Double(bytes[i]) / 255 - expected.r), abs(Double(bytes[i + 1]) / 255 - expected.g))
            }
        }
        #expect(worst < 0.07, "Rotated pattern differs from the expected upright pattern by \(worst)")
    }

    @Test func mixedSizesFormatsAndProxiesRenderAtOneSizeWithExactCuts() async throws {
        let temp = try TempDirectory()
        let numbersA = try await numberedAsset(temp, name: "A")
        let numbersD = try await numberedAsset(temp, name: "D")
        let eightBit = try await patternAsset(temp, name: "B", frames: 12, codec: .h264, width: 320, height: 180)
        let proxyD = try await ProxyGenerator.generate(
            source: numbersD.url, destination: temp.url.appendingPathComponent("D-proxy.mov"), maximumSize: CGSize(width: 128, height: 72)
        ).url

        var clips = [
            TimelineClip(assetID: numbersA.id, timelineStartFrame: 0, sourceStartFrame: 100, durationFrames: 10),
            TimelineClip(assetID: eightBit.id, timelineStartFrame: 10, sourceStartFrame: 0, durationFrames: 10),
            TimelineClip(assetID: numbersD.id, timelineStartFrame: 20, sourceStartFrame: 150, durationFrames: 10)
        ]
        var media = [numbersA, eightBit, numbersD]
        var expectedFrames = 30
        if let logAsset = try await fullRangeAsset(temp, width: 640, height: 360) {
            clips.append(TimelineClip(assetID: logAsset.id, timelineStartFrame: 30, sourceStartFrame: 0, durationFrames: 6))
            media.append(logAsset)
            expectedFrames = 36
        }

        let (item, result) = try await compose(clips, media, quality: .preview, proxies: [numbersD.id: proxyD])
        #expect(result.usedProxyCount == 1)
        #expect(item.videoComposition?.renderSize == CGSize(width: 128, height: 72), "The proxy sets the render size")

        let frames = try await allFrames(item, pixelFormat: kCVPixelFormatType_64RGBAHalf)
        #expect(frames.count == expectedFrames)
        #expect(frames.allSatisfy { CVPixelBufferGetWidth($0) == 128 && CVPixelBufferGetHeight($0) == 72 }, "One render size at every cut")

        // Frame-numbered clips cross the cuts exactly: 100…109 at 0…9, then 150…159 at 20…29.
        func number(_ frame: CVPixelBuffer) -> Int {
            let row = halfPixels(frame, row: 36)
            var value = 0
            for bit in 0 ..< 8 { value = value << 1 | (row[bit * 16 + 8].x > 0.5 ? 1 : 0) }
            return value
        }
        #expect((0 ..< 10).map { number(frames[$0]) } == Array(100 ..< 110))
        #expect((20 ..< 30).map { number(frames[$0]) } == Array(150 ..< 160))
    }

    @Test func aGapInTheTimelineRendersBlack() async throws {
        let temp = try TempDirectory()
        let numbers = try await numberedAsset(temp)
        let ghost = MediaAsset(url: temp.url.appendingPathComponent("gone.mov"), kind: .video, durationSeconds: 1)
        let clips = [
            TimelineClip(assetID: numbers.id, timelineStartFrame: 0, sourceStartFrame: 100, durationFrames: 10),
            TimelineClip(assetID: ghost.id, timelineStartFrame: 10, durationFrames: 10),
            TimelineClip(assetID: numbers.id, timelineStartFrame: 20, sourceStartFrame: 150, durationFrames: 10)
        ]
        let (item, result) = try await compose(clips, [numbers, ghost], quality: .preview)
        #expect(result.warnings.contains { $0.contains("gone.mov") })
        let samples = try await allSamples(item, pixelFormat: kCVPixelFormatType_64RGBAHalf)
        // AVFoundation answers an empty edit with one frame that lasts the whole gap: 10 + 1 + 10 frames.
        #expect(samples.count == 21)
        let rate = FrameRate.ntsc23976
        #expect(samples[9].start == rate.time(ofFrame: 9))
        #expect(samples[10].start == rate.time(ofFrame: 10), "The black frame starts where the gap does")
        #expect(samples[11].start == rate.time(ofFrame: 20), "…and the next clip starts where the gap ends")
        #expect(halfPixels(samples[10].buffer, row: 45).allSatisfy { $0 == SIMD3<Float>(0, 0, 0) }, "The gap is black")
        #expect(halfPixels(samples[9].buffer, row: 45).contains { $0.x > 0.5 } && halfPixels(samples[11].buffer, row: 45).contains { $0.x > 0.5 })
    }

    @Test func framesStayExactWhenEveryCutGoesThroughTheCompositor() async throws {
        let temp = try TempDirectory()
        let numbers = try await numberedAsset(temp)
        var ranges: [(start: Int, count: Int)] = (0 ..< 40).map { ((($0 * 37) + 11) % 240, 1) }
        ranges += [(5, 20), (133, 20)]
        var cursor: Int64 = 0
        let clips = ranges.map { range -> TimelineClip in
            defer { cursor += Int64(range.count) }
            return TimelineClip(assetID: numbers.id, timelineStartFrame: cursor, sourceStartFrame: Int64(range.start), durationFrames: Int64(range.count))
        }
        let (item, _) = try await compose(clips, [numbers])
        let expected = ranges.flatMap { range in (0 ..< range.count).map { range.start + $0 } }
        let shown = try await shownFrameNumbers(item, frames: expected.count)
        #expect(shown == expected)
    }

    // MARK: Requests

    @Test func manyQuickSeeksLeaveNothingPending() async throws {
        let temp = try TempDirectory()
        let numbers = try await numberedAsset(temp)
        let clip = TimelineClip(assetID: numbers.id, durationFrames: 240)
        let key = UUID()
        let (item, _) = try await compose([clip], [numbers], statisticsKey: key)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        while item.status == .unknown { try await Task.sleep(for: .milliseconds(10)) }
        #expect(item.status == .readyToPlay)

        let frame = CMTime(value: 1001, timescale: 24000)
        for index in 0 ..< 50 {
            player.seek(to: CMTimeMultiply(frame, multiplier: Int32((index * 7) % 230)), toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
            _ = output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil)
            try await Task.sleep(for: .milliseconds(20))
        }
        await player.seek(to: CMTimeMultiply(frame, multiplier: 120), toleranceBefore: .zero, toleranceAfter: .zero)

        let deadline = ContinuousClock.now + .seconds(5)
        var statistics = TimelineVideoCompositor.statistics(for: key)
        while ContinuousClock.now < deadline, statistics.pending > 0 || statistics.started == 0 {
            try await Task.sleep(for: .milliseconds(50))
            statistics = TimelineVideoCompositor.statistics(for: key)
        }
        print("Seek storm: \(statistics)")
        #expect(statistics.started > 0, "The seeks must have asked the compositor for frames")
        #expect(statistics.pending == 0, "Requests left pending: \(statistics)")
        #expect(statistics.failed == 0)
        #expect(statistics.maximumInFlight <= 2, "More frames in flight than the pool allows: \(statistics)")
    }
}

struct VideoTexturePoolTests {
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func reusingTexturesDoesNotGrowTheAllocation() throws {
        let pool = VideoTexturePool(device: try #require(MTLCreateSystemDefaultDevice()), maximumFreeTextures: 4)
        for _ in 0 ..< 50 {
            let textures = (0 ..< 3).map { _ in pool.acquire(width: 256, height: 144) }
            textures.forEach(pool.release)
        }
        #expect(pool.allocatedCount == 3, "Fifty rounds of three textures reuse the same three")
        let big = pool.acquire(width: 512, height: 288)
        pool.release(big)
        #expect(pool.allocatedCount == 4)
        pool.flush()
        #expect(pool.freeCount == 0)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func theFreeListIsBounded() throws {
        let pool = VideoTexturePool(device: try #require(MTLCreateSystemDefaultDevice()), maximumFreeTextures: 2)
        let textures = (0 ..< 6).map { _ in pool.acquire(width: 64, height: 64) }
        textures.forEach(pool.release)
        #expect(pool.freeCount == 2, "Extra textures are dropped, not hoarded")
    }
}

struct SourceOrientationTests {
    @Test func identityAndQuarterTurnsMapCornersCorrectly() {
        let size = CGSize(width: 192, height: 108)
        #expect(SourceOrientation(preferredTransform: .identity, sourceSize: size).isIdentity)
        let clockwise = SourceOrientation(preferredTransform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 108, ty: 0), sourceSize: size)
        #expect(clockwise.orientedSize == CGSize(width: 108, height: 192))
        // The oriented top-left (0, 0) is the stored bottom-left (0, 108)…
        #expect(clockwise.sourcePoint(forOrientedPoint: CGPoint(x: 0, y: 0)) == CGPoint(x: 0, y: 108))
        // …and the oriented bottom-right (108, 192) is the stored top-right (192, 0).
        #expect(clockwise.sourcePoint(forOrientedPoint: CGPoint(x: 108, y: 192)) == CGPoint(x: 192, y: 0))
        let upsideDown = SourceOrientation(preferredTransform: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 192, ty: 108), sourceSize: size)
        #expect(upsideDown.orientedSize == size && !upsideDown.isIdentity)
        #expect(upsideDown.sourcePoint(forOrientedPoint: CGPoint(x: 0, y: 0)) == CGPoint(x: 192, y: 108))
    }
}

struct VideoCompositingEnginePressureTests {
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func memoryPressureEmptiesTheFreeList() throws {
        let engine = try #require(VideoCompositingEngine.shared)
        engine.pool.release(engine.pool.acquire(width: 32, height: 32))
        #expect(engine.pool.freeCount > 0)
        VideoCompositingEngine.releaseMemoryUnderPressure()
        #expect(engine.pool.freeCount == 0)
    }
}
