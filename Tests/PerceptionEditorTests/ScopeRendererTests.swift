@preconcurrency import AVFoundation
import Foundation
import Metal
import Testing
@testable import PerceptionEditor

@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct ScopeRendererTests {
    static let bars: [SIMD3<Float>] = [[0.75, 0.75, 0.75], [0.75, 0.75, 0], [0, 0.75, 0.75], [0, 0.75, 0],
                                       [0.75, 0, 0.75], [0.75, 0, 0], [0, 0, 0.75], [0, 0, 0]]

    /// A `rgba16Float` frame of eight vertical bars (or one flat color).
    static func frame(width: Int = 512, height: Int = 64, colors: [SIMD3<Float>] = bars) throws -> MTLTexture {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        var halves = [Float16](repeating: 1, count: width * height * 4)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let c = colors[x * colors.count / width]
                let i = (y * width + x) * 4
                halves[i] = Float16(c.x); halves[i + 1] = Float16(c.y); halves[i + 2] = Float16(c.z)
            }
        }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: halves, bytesPerRow: width * 8)
        return texture
    }

    static func luma(_ c: SIMD3<Float>) -> Float { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }

    /// The bin (0…bins−1) holding the most counts in one waveform column.
    static func peak(_ analysis: ScopeAnalysis, column: Int) -> Int {
        let start = column * analysis.bins
        let counts = analysis.waveform[start ..< start + analysis.bins]
        return counts.indices.max { counts[$0] < counts[$1] }! - start
    }

    @Test func lumaWaveformPeaksAtEachBarsCodeValue() throws {
        let renderer = try ScopeRenderer()
        let analysis = try renderer.analyze(try Self.frame(), mode: .luma)
        #expect(analysis.columns == 512 && analysis.bins == 1024)
        for (index, bar) in Self.bars.enumerated() {
            let column = index * 64 + 32 // The middle of the bar.
            let expected = Int((Self.luma(bar) * 1023).rounded())
            #expect(abs(Self.peak(analysis, column: column) - expected) <= 1, "Bar \(index): peak \(Self.peak(analysis, column: column)), expected \(expected)")
        }
        #expect(analysis.waveform.reduce(0, +) == 512 * 64, "Every pixel lands in exactly one bin")
    }

    @Test func rgbParadeShowsEachChannelInItsOwnThird() throws {
        let renderer = try ScopeRenderer()
        let analysis = try renderer.analyze(try Self.frame(), mode: .rgbParade)
        let panel = analysis.columns / 3
        for channel in 0 ..< 3 {
            for (index, bar) in Self.bars.enumerated() {
                let column = channel * panel + (index * panel + panel / 2) / Self.bars.count
                let expected = Int((bar[channel] * 1023).rounded())
                #expect(abs(Self.peak(analysis, column: column) - expected) <= 1, "Channel \(channel), bar \(index)")
            }
        }
    }

    @Test func vectorscopePutsEachBarInItsTargetBox() throws {
        let renderer = try ScopeRenderer()
        let analysis = try renderer.analyze(try Self.frame(), mode: .luma)
        for bar in Self.bars {
            let y = Self.luma(bar)
            let cb = (bar.z - y) / (2 * (1 - 0.0722)), cr = (bar.x - y) / (2 * (1 - 0.2126))
            let target = ScopeRenderer.vectorscopeBin(cb: cb, cr: cr, size: analysis.size)
            var near: UInt32 = 0
            for v in target.v - 1 ... target.v + 1 { for u in target.u - 1 ... target.u + 1 { near += analysis.vectorscope[v * analysis.size + u] } }
            #expect(near == 64 * 64 || (bar.x == bar.y && bar.y == bar.z), "Bar \(bar): \(near) of 4096 pixels near its target")
        }
    }

    @Test func aFlatGreyFrameIsAllInTheCenterBin() throws {
        let renderer = try ScopeRenderer()
        let analysis = try renderer.analyze(try Self.frame(colors: [SIMD3(repeating: 0.42)]), mode: .luma)
        let center = ScopeRenderer.vectorscopeBin(cb: 0, cr: 0, size: analysis.size)
        #expect(analysis.vectorscope[center.v * analysis.size + center.u] == 512 * 64)
    }

    @Test func aFlatGreyFrameFillsOneHistogramBin() throws {
        let renderer = try ScopeRenderer()
        let analysis = try renderer.analyze(try Self.frame(colors: [SIMD3(repeating: 0.42)]), mode: .luma)
        let bin = Int((Float(Float16(0.42)) * 255).rounded())
        for channel in [analysis.histogram.red, analysis.histogram.green, analysis.histogram.blue] {
            #expect(channel.count == 256)
            #expect(channel[bin] == 1, "The grey's bin is the peak")
            #expect(channel.enumerated().allSatisfy { $0.offset == bin || $0.element == 0 }, "Every other bin is empty")
        }
    }

    @Test func barsPutEachChannelWhereTheyBelong() throws {
        let renderer = try ScopeRenderer()
        // Half the bars carry each channel at 75% (code 191), the other half at 0.
        let bars = try renderer.analyze(try Self.frame(), mode: .luma).histogram
        for channel in [bars.red, bars.green, bars.blue] {
            #expect(channel[0] == 1 && channel[191] == 1, "Equal shares of the frame: both are peaks")
            #expect(channel.enumerated().allSatisfy { [0, 191].contains($0.offset) || $0.element == 0 })
        }
        // Three red bars of four: 191 holds three times the pixels of 0, so 0 normalizes to a third.
        let red: [SIMD3<Float>] = [[0.75, 0, 0], [0.75, 0, 0], [0.75, 0, 0], [0, 0, 0]]
        let uneven = try renderer.analyze(try Self.frame(colors: red), mode: .luma).histogram
        #expect(uneven.red[191] == 1 && abs(uneven.red[0] - 1.0 / 3) < 1e-9)
        #expect(uneven.green[0] == 1 && uneven.green[191] == 0 && uneven.blue[0] == 1)
    }

    @Test func everyPixelIsCountedOnceOnAFrameThatIsNotAMultipleOfTheThreadgroup() throws {
        let renderer = try ScopeRenderer()
        let analysis = try renderer.analyze(try Self.frame(width: 500, height: 37), mode: .luma)
        for channel in 0 ..< 3 {
            let total = analysis.histogramCounts[channel * 256 ..< (channel + 1) * 256].reduce(0, +)
            #expect(total == 500 * 37, "Channel \(channel) counted \(total) pixels")
        }
    }

    @Test func outOfRangeAndNaNValuesLandInTheEndBins() throws {
        let renderer = try ScopeRenderer()
        // Per pixel: red below 0 / above 1 / NaN / 1, green and blue fixed.
        let colors: [SIMD3<Float>] = [[-0.5, 2, .nan], [3, -1, 0.5], [.nan, 1, 0], [1, 0, 1]]
        let analysis = try renderer.analyze(try Self.frame(width: 64, height: 8, colors: colors), mode: .luma)
        let each = UInt32(64 * 8 / 4)
        func count(_ channel: Int, _ bin: Int) -> UInt32 { analysis.histogramCounts[channel * 256 + bin] }
        #expect(count(0, 0) == 2 * each && count(0, 255) == 2 * each, "Red: -0.5 and NaN at 0, 3 and 1 at 255")
        #expect(count(1, 0) == 2 * each && count(1, 255) == 2 * each)
        #expect(count(2, 0) == 2 * each && count(2, 255) == each && count(2, 128) == each, "Blue: NaN and 0 at 0, 1 at 255, 0.5 at 128")
        for channel in 0 ..< 3 {
            #expect(analysis.histogramCounts[channel * 256 ..< (channel + 1) * 256].reduce(0, +) == 64 * 8)
        }
    }

    @Test func imagesHaveTheirSizesAndShowTheGuides() throws {
        let renderer = try ScopeRenderer()
        let analysis = try renderer.analyze(try Self.frame(colors: [SIMD3(repeating: 0.42)]), mode: .luma)
        #expect(analysis.waveformImage.width == 512 && analysis.waveformImage.height == 512)
        #expect(analysis.vectorscopeImage.width == 512 && analysis.vectorscopeImage.height == 512)
        // The 940 guide row is lit even where no pixel falls.
        let row = ScopeRenderer.waveformRow(forCode: 940, height: analysis.waveformImage.height)
        #expect(Self.brightness(analysis.waveformImage, x: 10, y: row) > 0.1)
        #expect(Self.brightness(analysis.waveformImage, x: 10, y: row + 6) < 0.05, "Away from the guide and the trace it is dark")
    }

    static func brightness(_ image: CGImage, x: Int, y: Int) -> Double {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return Double(max(pixel[0], pixel[1], pixel[2])) / 255
    }
}

struct ScopeTapTests {
    @Test func aDisabledTapCapturesNothing() {
        let tap = ScopeTap(minimumInterval: 0)
        #expect(!tap.shouldCapture(now: 0))
        tap.isEnabled = true
        #expect(tap.shouldCapture(now: 0) && tap.shouldCapture(now: 0))
    }

    @Test func captureIsThrottled() {
        let tap = ScopeTap(minimumInterval: 1.0 / 15)
        tap.isEnabled = true
        #expect(tap.shouldCapture(now: 10))
        #expect(!tap.shouldCapture(now: 10.03), "At most 15 captures a second")
        #expect(tap.shouldCapture(now: 10.07))
    }

    @Test func playbackCapturesEverySecondFrameHoweverItIsRendered() {
        let tap = ScopeTap()
        tap.isEnabled = true
        // 24 fps frames rendered in a burst, all within a millisecond.
        let captured = (0 ..< 12).filter { tap.shouldCapture(compositionSeconds: Double($0) / 24, now: 5 + Double($0) * 0.0001) }
        #expect(captured == [0, 2, 4, 6, 8, 10])
        // After a pause in rendering, the next frame (a one-frame step) is captured.
        #expect(tap.shouldCapture(compositionSeconds: 11.0 / 24, now: 6))
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func theTapReusesAFewTexturesAndKeepsOnlyTheLatest() throws {
        let tap = ScopeTap(minimumInterval: 0)
        let device = try #require(MTLCreateSystemDefaultDevice())
        var seen = Set<ObjectIdentifier>()
        for _ in 0 ..< 20 {
            let texture = try #require(tap.captureTexture(device: device, width: 512, height: 288))
            seen.insert(ObjectIdentifier(texture))
            tap.publish(texture)
        }
        #expect(seen.count <= ScopeTap.ringSize, "Captures cycle through \(ScopeTap.ringSize) textures, not one per frame")
        #expect(tap.latest != nil)
    }
}

/// The compositor feeds the tap only while scopes are visible.
@MainActor
@Suite(.serialized, .enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct ScopeCompositorTests {
    @Test func previewFramesReachTheTapOnlyWhileItIsEnabled() async throws {
        let temp = try TempDirectory()
        let movie = try await writeColorPatternMovie(to: temp.url.appendingPathComponent("p.mov"), frames: 24)
        let asset = MediaAsset(url: movie, kind: .video, durationSeconds: 1, frameRate: .ntsc23976, frameCount: 24)
        let clip = TimelineClip(assetID: asset.id, durationFrames: 24)
        let tap = ScopeTap.shared

        func readAll() async throws {
            let item = try #require(await TimelineCompositionService.shared.makePlayerItem(
                clips: [clip], media: [asset], quality: .preview, renderingPath: .compositor
            ).playerItem)
            let tracks = try await item.asset.loadTracks(withMediaType: .video)
            let reader = try AVAssetReader(asset: item.asset)
            let output = AVAssetReaderVideoCompositionOutput(videoTracks: tracks, videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf])
            output.videoComposition = item.videoComposition
            reader.add(output)
            #expect(reader.startReading())
            let box = Unchecked(value: output)
            try await Task.detached { while box.value.copyNextSampleBuffer() != nil {} }.value
        }

        tap.isEnabled = false
        let before = tap.capturedCount
        try await readAll()
        #expect(tap.capturedCount == before, "No scope work while the panel is hidden")

        let savedInterval = tap.minimumInterval
        tap.minimumInterval = 0
        tap.isEnabled = true
        defer { tap.isEnabled = false; tap.minimumInterval = savedInterval }
        let publishedBefore = tap.publishedCount
        try await readAll()
        try await waitUntil { tap.publishedCount > publishedBefore }
        #expect(tap.publishedCount > publishedBefore)
        let latest = try #require(tap.latest)
        #expect(latest.width == 512 && latest.height == 288, "A 192×108 frame is captured at 512 wide, keeping its shape")
    }

    @Test func theScopePanelTurnsTheTapOnAndOff() throws {
        let temp = try TempDirectory()
        let suite = "pme-scope-tests-\(UUID().uuidString)"
        let store = EditorStore(
            presetRepository: UserPresetRepository(defaults: UserDefaults(suiteName: suite)!),
            proxyStore: ProxyStore(directory: try temp.subdirectory("Proxy Cache"), availableBytes: { _ in 1 << 40 }),
            proxyDefaults: UserDefaults(suiteName: suite)!,
            lutLibrary: LUTLibrary(directory: temp.url.appendingPathComponent("Library"))
        )
        defer { store.scopesVisible = false }
        #expect(!ScopeTap.shared.isEnabled)
        store.scopeSource = .source
        store.scopesVisible = true
        #expect(ScopeTap.shared.isEnabled && ScopeTap.shared.source == .source)
        store.scopesVisible = false
        #expect(!ScopeTap.shared.isEnabled)
    }

    private struct Unchecked<Value>: @unchecked Sendable { let value: Value }
}
