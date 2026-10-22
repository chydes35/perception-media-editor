// Writes a ProRes 422 Proxy the way ProxyGenerator does, but at full size and with a chosen read format,
// so stored code values can be compared pixel-for-pixel with the original.
import AVFoundation
import Foundation

func code(_ s: String) -> OSType { s.utf8.reduce(0) { ($0 << 8) | OSType($1) } }

let args = CommandLine.arguments
let src = URL(fileURLWithPath: args[1]), dst = URL(fileURLWithPath: args[2])
let readFormat = code(args[3])
let seconds = Double(args[4]) ?? 1
try? FileManager.default.removeItem(at: dst)

let sem = DispatchSemaphore(value: 0)
Task {
    do {
        let asset = AVURLAsset(url: src)
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let (size, range, formats) = try await track.load(.naturalSize, .timeRange, .formatDescriptions)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: range.start, duration: CMTime(seconds: seconds, preferredTimescale: 24000))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: readFormat])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        let writer = try AVAssetWriter(outputURL: dst, fileType: .mov)
        var colors: [String: Any] = [:]
        if let f = formats.first, let ext = CMFormatDescriptionGetExtensions(f) as? [String: Any] {
            colors[AVVideoColorPrimariesKey] = ext[kCMFormatDescriptionExtension_ColorPrimaries as String]
            colors[AVVideoTransferFunctionKey] = ext[kCMFormatDescriptionExtension_TransferFunction as String]
            colors[AVVideoYCbCrMatrixKey] = ext[kCMFormatDescriptionExtension_YCbCrMatrix as String]
            print("source full-range extension:", ext[kCMFormatDescriptionExtension_FullRangeVideo as String] ?? "nil")
        }
        var settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.proRes422Proxy,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: colors
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        reader.startReading(); writer.startWriting(); writer.startSession(atSourceTime: range.start)
        var n = 0
        while let sb = output.copyNextSampleBuffer() {
            while !input.isReadyForMoreMediaData { usleep(1000) }
            input.append(sb); n += 1
        }
        input.markAsFinished()
        await writer.finishWriting()
        print("wrote \(n) frames status \(writer.status.rawValue) \(String(describing: writer.error))")
    } catch { print("error \(error)") }
    sem.signal()
}
sem.wait()
