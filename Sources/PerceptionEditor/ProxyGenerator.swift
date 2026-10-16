// Sources/PerceptionEditor/ProxyGenerator.swift
@preconcurrency import AVFoundation
import Foundation

struct ProxyInfo: Equatable, Sendable {
    var url: URL
    var frameCount: Int
    var pixelWidth: Int
    var pixelHeight: Int
}

enum ProxyError: LocalizedError, Equatable {
    case noVideoTrack
    case readFailed(String)
    case writeFailed(String)
    case validationFailed(String)
    case insufficientSpace(neededBytes: Int64, availableBytes: Int64)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: "The file has no video track."
        case .readFailed(let reason): "The original could not be read: \(reason)"
        case .writeFailed(let reason): "The proxy could not be written: \(reason)"
        case .validationFailed(let reason): "The proxy did not match the original: \(reason)"
        case .insufficientSpace(let needed, let available):
            "Not enough free space for a proxy (needs \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)), \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) free)."
        }
    }
}

/// Transcodes one original into a ProRes 422 Proxy for editing. Frames are read as 10-bit 4:2:2;
/// asking the decoder for BGRA cut throughput to a quarter on the target M1 (12 fps vs 45 fps).
enum ProxyGenerator {
    static let defaultMaximumSize = CGSize(width: 1920, height: 1080)
    /// Measured on Lumix S5 UHD 23.976 footage: 44 MB per 10 s of 1080p ProRes 422 Proxy.
    static let bytesPerSecondAt1080p: Double = 4_500_000

    static func proxySize(for source: CGSize, maximum: CGSize = defaultMaximumSize) -> CGSize {
        guard source.width > 0, source.height > 0 else { return maximum }
        let scale = min(1, maximum.width / source.width, maximum.height / source.height)
        func even(_ value: CGFloat) -> CGFloat { max(2, (value * scale / 2).rounded() * 2) }
        return CGSize(width: even(source.width), height: even(source.height))
    }

    static func estimatedBytes(durationSeconds: Double, proxySize: CGSize) -> Int64 {
        let pixelRatio = (proxySize.width * proxySize.height) / (1920 * 1080)
        return Int64(max(0, durationSeconds) * bytesPerSecondAt1080p * Double(pixelRatio))
    }

    static func generate(
        source: URL,
        destination: URL,
        maximumSize: CGSize = defaultMaximumSize,
        progress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> ProxyInfo {
        let fileManager = FileManager.default
        let partial = destination.deletingPathExtension().appendingPathExtension("partial.mov")
        try? fileManager.removeItem(at: partial)
        defer { try? fileManager.removeItem(at: partial) } // Already moved on success.

        let asset = AVURLAsset(url: source)
        let tracks: [AVAssetTrack]
        do { tracks = try await asset.loadTracks(withMediaType: .video) } catch {
            try Task.checkCancellation() // A cancelled load must stay a cancellation, not "no video track".
            throw ProxyError.noVideoTrack
        }
        guard let track = tracks.first else { throw ProxyError.noVideoTrack }
        let (naturalSize, transform, timeRange, formats) = try await track.load(
            .naturalSize, .preferredTransform, .timeRange, .formatDescriptions
        )
        try Task.checkCancellation()
        let size = proxySize(for: naturalSize, maximum: maximumSize)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)

        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: partial, fileType: .mov) } catch {
            throw ProxyError.writeFailed(error.localizedDescription)
        }
        var settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.proRes422Proxy,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect
        ]
        if let format = formats.first, let colors = colorProperties(format) {
            settings[AVVideoColorPropertiesKey] = colors
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.transform = transform
        input.expectsMediaDataInRealTime = false
        writer.add(input)

        guard reader.startReading() else {
            throw ProxyError.readFailed(reader.error?.localizedDescription ?? "unknown error")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw ProxyError.writeFailed(writer.error?.localizedDescription ?? "unknown error")
        }
        writer.startSession(atSourceTime: timeRange.start)

        var written = 0
        let total = max(timeRange.duration.seconds, 0.001)
        do {
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
                guard input.append(sample) else {
                    throw ProxyError.writeFailed(writer.error?.localizedDescription ?? "append failed")
                }
                written += 1
                progress(min(1, (sample.presentationTimeStamp - timeRange.start).seconds / total))
            }
            try Task.checkCancellation()
            if reader.status == .failed {
                throw ProxyError.readFailed(reader.error?.localizedDescription ?? "unknown error")
            }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw ProxyError.writeFailed(writer.error?.localizedDescription ?? "finish failed")
        }

        let proxyFrames = try await frameCount(at: partial)
        guard proxyFrames == written, written > 0 else {
            throw ProxyError.validationFailed("\(proxyFrames) proxy frames, \(written) source frames")
        }
        let proxyTrack = try await AVURLAsset(url: partial).loadTracks(withMediaType: .video)[0]
        let proxyRange = try await proxyTrack.load(.timeRange)
        let frameSeconds = 1.0 / Double(max(1, try await track.load(.nominalFrameRate)))
        guard abs(proxyRange.duration.seconds - timeRange.duration.seconds) <= frameSeconds + 0.0005 else {
            throw ProxyError.validationFailed("duration \(proxyRange.duration.seconds)s vs \(timeRange.duration.seconds)s")
        }

        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.moveItem(at: partial, to: destination)
        progress(1)
        return ProxyInfo(url: destination, frameCount: written, pixelWidth: Int(size.width), pixelHeight: Int(size.height))
    }

    /// Counts frames without decoding them.
    static func frameCount(at url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ProxyError.noVideoTrack }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { throw ProxyError.readFailed(reader.error?.localizedDescription ?? "unknown") }
        var count = 0
        while let sample = output.copyNextSampleBuffer() { count += CMSampleBufferGetNumSamples(sample) }
        guard reader.status == .completed else { throw ProxyError.readFailed(reader.error?.localizedDescription ?? "unknown") }
        return count
    }

    /// AVFoundation requires all three color keys together. A source missing any of them stays untagged.
    private static func colorProperties(_ format: CMFormatDescription) -> [String: String]? {
        func value(_ key: CFString) -> String? { CMFormatDescriptionGetExtension(format, extensionKey: key) as? String }
        guard let primaries = value(kCMFormatDescriptionExtension_ColorPrimaries),
              let transfer = value(kCMFormatDescriptionExtension_TransferFunction),
              let matrix = value(kCMFormatDescriptionExtension_YCbCrMatrix) else { return nil }
        return [
            AVVideoColorPrimariesKey: primaries,
            AVVideoTransferFunctionKey: transfer,
            AVVideoYCbCrMatrixKey: matrix
        ]
    }
}
