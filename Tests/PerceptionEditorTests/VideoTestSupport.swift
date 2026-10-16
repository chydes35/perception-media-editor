// Tests/PerceptionEditorTests/VideoTestSupport.swift
@preconcurrency import AVFoundation
import Foundation
import Testing
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
