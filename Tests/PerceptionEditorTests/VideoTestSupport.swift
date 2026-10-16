// Tests/PerceptionEditorTests/VideoTestSupport.swift
@preconcurrency import AVFoundation
import Foundation
import Testing
import VideoToolbox
@testable import PerceptionEditor

/// Writes a small ProRes 422 movie whose frames step from black to white, tagged Rec. 709,
/// at 23.976 fps, so proxy tests exercise the same frame timing as Lumix footage. With `withAudio`
/// it also carries a silent 48 kHz mono LPCM track, interleaved frame by frame.
@discardableResult
func writeTestMovie(
    to url: URL,
    frames: Int = 24,
    width: Int = 640,
    height: Int = 360,
    transform: CGAffineTransform = .identity,
    withAudio: Bool = false
) async throws -> URL {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    writer.movieTimeScale = 24000
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.proRes422,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoColorPropertiesKey: [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
        ]
    ])
    input.expectsMediaDataInRealTime = false
    // Lumix files keep 1001/24000 frame times exactly; the writer's default 600 would round them.
    input.mediaTimeScale = 24000
    input.transform = transform
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height
    ])
    writer.add(input)
    let audio = withAudio ? try SilentAudioTrack(writer: writer) : nil
    guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    writer.startSession(atSourceTime: .zero)

    let frameDuration = CMTime(value: 1001, timescale: 24000)
    // The writer holds back whichever track runs ahead, so feed whichever input is ready.
    var videoIndex = 0
    var audioIndex = withAudio ? 0 : frames
    while videoIndex < frames || audioIndex < frames {
        var progressed = false
        if let audio, audioIndex < frames, audio.input.isReadyForMoreMediaData {
            try audio.append(frame: audioIndex)
            audioIndex += 1
            if audioIndex == frames { audio.input.markAsFinished() }
            progressed = true
        }
        if videoIndex < frames, input.isReadyForMoreMediaData {
            let index = videoIndex
            guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
            var created: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created)
            guard let buffer = created else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(buffer, [])
            let shade = Int32(index * 255 / max(1, frames - 1))
            memset(CVPixelBufferGetBaseAddress(buffer), shade, CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTimeMultiply(frameDuration, multiplier: Int32(index))) else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
            videoIndex += 1
            if videoIndex == frames { input.markAsFinished() }
            progressed = true
        }
        if !progressed { try await Task.sleep(for: .milliseconds(1)) }
    }
    await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    return url
}

/// Silence covering exactly one 1001/24000 s video frame per append (2002 samples at 48 kHz).
private struct SilentAudioTrack {
    static let samplesPerFrame = 2002
    let input: AVAssetWriterInput
    let format: CMAudioFormatDescription

    init(writer: AVAssetWriter) throws {
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
            mBitsPerChannel: 16, mReserved: 0
        )
        var created: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &created
        )
        guard let created else { throw CocoaError(.fileWriteUnknown) }
        format = created
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        input.expectsMediaDataInRealTime = false
        writer.add(input)
    }

    func append(frame index: Int) throws {
        let count = Self.samplesPerFrame
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: count * 2, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: count * 2,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        )
        guard let block else { throw CocoaError(.fileWriteUnknown) }
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: count * 2)
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: count,
            presentationTimeStamp: CMTime(value: CMTimeValue(index * count), timescale: 48_000),
            packetDescriptions: nil, sampleBufferOut: &sample
        )
        guard let sample, input.append(sample) else { throw CocoaError(.fileWriteUnknown) }
    }
}

/// Polls until the asset's proxy is ready or failed.
@MainActor
func waitForProxy(_ store: ProxyStore, _ id: UUID, timeout: Duration = .seconds(60)) async throws -> ProxyStatus {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        switch store.statuses[id] {
        case .ready?, .failed?: return store.statuses[id]!
        default: try await Task.sleep(for: .milliseconds(20))
        }
    }
    Issue.record("Proxy for \(id) did not finish within \(timeout)")
    return store.statuses[id] ?? .missing
}

/// Writes a full-range 10-bit movie like the S5's V-Log files (which are full range and tagged BT.709):
/// luma ramps 0…1023 across the width and chroma ramps 384…640 down the height. It tries HEVC 4:2:2
/// first, then HEVC 4:2:0, and returns nil when this machine can encode neither.
func writeFullRangeTestMovie(to url: URL, frames: Int = 6, width: Int = 640, height: Int = 360) async throws -> URL? {
    let candidates: [(OSType, String)] = [
        (kCVPixelFormatType_422YpCbCr10BiPlanarFullRange, kVTProfileLevel_HEVC_Main42210_AutoLevel as String),
        (kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, kVTProfileLevel_HEVC_Main10_AutoLevel as String)
    ]
    for (format, profile) in candidates {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieTimeScale = 24000
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoProfileLevelKey: profile, AVVideoQualityKey: 1.0],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ])
        input.expectsMediaDataInRealTime = false
        // Lumix files keep 1001/24000 frame times exactly; the writer's default 600 would round them.
        input.mediaTimeScale = 24000
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: format,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ])
        writer.add(input)
        guard writer.startWriting() else { continue }
        writer.startSession(atSourceTime: .zero)
        var failed = false
        for index in 0 ..< frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            var created: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool,
                  CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created) == kCVReturnSuccess,
                  let buffer = created else { failed = true; break }
            fillFullRangeRamp(buffer)
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index) * 1001, timescale: 24000)) else {
                failed = true; break
            }
        }
        if failed { writer.cancelWriting(); continue }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status == .completed { return url }
    }
    return nil
}

private func fillFullRangeRamp(_ buffer: CVPixelBuffer) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let width = CVPixelBufferGetWidth(buffer)
    for plane in 0 ..< 2 {
        let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
        let rows = CVPixelBufferGetHeightOfPlane(buffer, plane)
        let samples = plane == 0 ? width : CVPixelBufferGetWidthOfPlane(buffer, plane) * 2
        for y in 0 ..< rows {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt16.self)
            for x in 0 ..< samples {
                let chroma = 384 + y * 256 / max(1, rows - 1)
                let value = plane == 0 ? x * 1023 / max(1, width - 1) : (x % 2 == 0 ? chroma : 1024 - chroma)
                row[x] = UInt16(value << 6) // 10-bit values sit in the top bits.
            }
        }
    }
}

/// Frame 0 of a movie as AVFoundation's own RGB conversion sees it (what AVPlayer and Core Image show),
/// sampled on a grid away from the edges.
func decodedRGBGrid(_ url: URL, columns: Int = 16, rows: Int = 9) async throws -> [SIMD3<Float>] {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf
    ])
    reader.add(output)
    #expect(reader.startReading())
    let sample = try #require(output.copyNextSampleBuffer())
    reader.cancelReading()
    let buffer = try #require(CMSampleBufferGetImageBuffer(sample))
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
    let stride = CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<Float16>.size
    let pixels = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: Float16.self)
    var values: [SIMD3<Float>] = []
    for row in 0 ..< rows {
        for column in 0 ..< columns {
            let x = (column * 2 + 1) * width / (columns * 2), y = (row * 2 + 1) * height / (rows * 2)
            let i = y * stride + x * 4
            values.append(SIMD3(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2])))
        }
    }
    return values
}

/// Frame 0's mean RGB (AVFoundation's conversion) in each cell of a grid. Means are comparable across
/// sizes, so an original and its smaller proxy can be checked against each other.
func decodedRGBCellMeans(_ url: URL, columns: Int = 16, rows: Int = 9) async throws -> [SIMD3<Float>] {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf
    ])
    reader.add(output)
    #expect(reader.startReading())
    let sample = try #require(output.copyNextSampleBuffer())
    reader.cancelReading()
    let buffer = try #require(CMSampleBufferGetImageBuffer(sample))
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
    let stride = CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<Float16>.size
    let pixels = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: Float16.self)
    var sums = [SIMD3<Float>](repeating: .zero, count: columns * rows)
    var counts = [Float](repeating: 0, count: columns * rows)
    for y in 0 ..< height {
        let cellRow = y * rows / height
        for x in 0 ..< width {
            let i = y * stride + x * 4
            let cell = cellRow * columns + x * columns / width
            sums[cell] += SIMD3(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2]))
            counts[cell] += 1
        }
    }
    return zip(sums, counts).map { $0 / $1 }
}

/// Writes a movie whose every frame shows its own index as 8 vertical bars (bit 7 on the left,
/// white = 1), at 23.976 fps, so a test can tell exactly which source frame a composition showed.
@discardableResult
func writeFrameNumberedMovie(to url: URL, frames: Int = 240, width: Int = 160, height: Int = 90) async throws -> URL {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    writer.movieTimeScale = 24000
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.proRes422,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height
    ])
    input.expectsMediaDataInRealTime = false
    // Lumix files keep 1001/24000 frame times exactly; the writer's default 600 would round them.
    input.mediaTimeScale = 24000
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height
    ])
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    writer.startSession(atSourceTime: .zero)
    for index in 0 ..< frames {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
        guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
        var created: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created)
        guard let buffer = created else { throw CocoaError(.fileWriteUnknown) }
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let bit = (index >> (7 - x * 8 / width)) & 1
                let value: UInt8 = bit == 1 ? 255 : 0
                let pixel = base + y * stride + x * 4
                pixel[0] = value; pixel[1] = value; pixel[2] = value; pixel[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index) * 1001, timescale: 24000)) else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    return url
}

/// The frame index drawn by `writeFrameNumberedMovie`, read from a decoded image.
func frameNumber(in image: CGImage) -> Int {
    let width = image.width, height = image.height
    var gray = [UInt8](repeating: 0, count: width * height)
    let context = CGContext(
        data: &gray, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
    )!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var value = 0
    for bit in 0 ..< 8 {
        let x = bit * width / 8 + width / 16
        value = value << 1 | (gray[(height / 2) * width + x] > 127 ? 1 : 0)
    }
    return value
}

/// Every frame a player item would show at the composition's frame times, decoded with zero tolerance.
@MainActor
func shownFrameNumbers(_ item: AVPlayerItem, frames: Int, frameDuration: CMTime = CMTime(value: 1001, timescale: 24000)) async throws -> [Int] {
    let generator = AVAssetImageGenerator(asset: item.asset)
    generator.videoComposition = item.videoComposition
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    var shown: [Int] = []
    for index in 0 ..< frames {
        let (image, _) = try await generator.image(at: CMTimeMultiply(frameDuration, multiplier: Int32(index)))
        shown.append(frameNumber(in: image))
    }
    return shown
}

/// The test pattern's R'G'B' at normalized position (u, v), both 0…1 from the top left: red ramps
/// across, green down, blue swirls, and the bottom tenth is a grey ramp. Smooth, so 4:2:0 and 4:2:2
/// chroma handling differences between decoders stay small.
func colorPatternRGB(u: Double, v: Double) -> (r: Double, g: Double, b: Double) {
    if v > 0.9 { return (u, u, u) }
    return (u, v / 0.9, 0.5 + 0.35 * sin(2 * .pi * (1.5 * u + 0.9 * v)))
}

/// Writes `frames` identical frames of the color pattern, tagged Rec. 709, at 23.976 fps.
@discardableResult
func writeColorPatternMovie(
    to url: URL,
    codec: AVVideoCodecType = .proRes422,
    frames: Int = 12,
    width: Int = 192,
    height: Int = 108,
    transform: CGAffineTransform = .identity
) async throws -> URL {
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    writer.movieTimeScale = 24000
    var settings: [String: Any] = [
        AVVideoCodecKey: codec,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoColorPropertiesKey: [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
        ]
    ]
    if codec == .h264 { settings[AVVideoCompressionPropertiesKey] = [AVVideoQualityKey: 1.0] }
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    input.mediaTimeScale = 24000
    input.transform = transform
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height
    ])
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    writer.startSession(atSourceTime: .zero)
    for index in 0 ..< frames {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
        guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
        var created: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created)
        guard let buffer = created else { throw CocoaError(.fileWriteUnknown) }
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let color = colorPatternRGB(u: (Double(x) + 0.5) / Double(width), v: (Double(y) + 0.5) / Double(height))
                let pixel = base + y * stride + x * 4
                pixel[0] = UInt8((color.b * 255).rounded()); pixel[1] = UInt8((color.g * 255).rounded())
                pixel[2] = UInt8((color.r * 255).rounded()); pixel[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index) * 1001, timescale: 24000)) else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    return url
}

/// The adjustments the golden frame was captured with: every stage of the color chain at once.
func goldenGradeAdjustments() -> PhotoAdjustments {
    var hsl = HSLAdjustments()
    hsl.blue = HSLBandAdjustment(hue: 0.2, saturation: 0.5, luminance: -0.3)
    hsl.red = HSLBandAdjustment(hue: 0, saturation: -0.3, luminance: 0.2)
    return PhotoAdjustments(
        exposure: 0.4, contrast: 0.15, highlights: -0.3, shadows: 0.2,
        temperature: 0.1, tint: -0.05, vibrance: 0.3, saturation: 0.2,
        sharpness: 0.3, vignette: 0.25,
        curves: ToneCurves(rgb: ToneCurve.presets[1].curve),
        hsl: hsl
    )
}
