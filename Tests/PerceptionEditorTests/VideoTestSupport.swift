// Tests/PerceptionEditorTests/VideoTestSupport.swift
@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import PerceptionEditor

/// Writes a small ProRes 422 movie whose frames step from black to white, tagged Rec. 709,
/// at 23.976 fps, so proxy tests exercise the same frame timing as Lumix footage.
@discardableResult
func writeTestMovie(
    to url: URL,
    frames: Int = 24,
    width: Int = 640,
    height: Int = 360,
    transform: CGAffineTransform = .identity
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
    guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    writer.startSession(atSourceTime: .zero)

    let frameDuration = CMTime(value: 1001, timescale: 24000)
    for index in 0 ..< frames {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
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
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    return url
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
