// Task 13.0 probe: what an iPhone clip says about itself. Prints the video format description's
// extensions (including kCMFormatDescriptionExtension_LogTransferFunction), the track's
// preferredTransform and timing, the file's metadata, the timed-metadata keys, and a histogram of
// frame durations read from the compressed samples. Opens the file read-only; writes nothing.
//
// Build and run (Command Line Tools):
//   SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swiftc -O scripts/video-probes/applelogprobe.swift -o "$TMPDIR/applelogprobe"
//   "$TMPDIR/applelogprobe" <clip.mov> [...]
import AVFoundation
import CoreMedia
import Foundation

func fourCC(_ value: FourCharCode) -> String {
    String([24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((value >> UInt32($0)) & 0xFF))) })
}

func describe(_ value: Any, indent: String = "    ") -> String {
    if let dictionary = value as? [String: Any] {
        return dictionary.keys.sorted().map { "\n\(indent)\($0): \(describe(dictionary[$0]!, indent: indent + "  "))" }.joined()
    }
    if let data = value as? Data { return "<\(data.count) bytes>" }
    return "\(value)"
}

func probe(_ url: URL) async throws {
    print("=== \(url.lastPathComponent)")
    let asset = AVURLAsset(url: url)
    let track = try await asset.loadTracks(withMediaType: .video).first!
    let (formats, transform, size, rate, minDuration, timeRange) = try await track.load(
        .formatDescriptions, .preferredTransform, .naturalSize, .nominalFrameRate, .minFrameDuration, .timeRange
    )
    print("  naturalSize \(Int(size.width))x\(Int(size.height)), preferredTransform \(transform)")
    print("  nominalFrameRate \(rate), minFrameDuration \(minDuration.value)/\(minDuration.timescale), duration \(timeRange.duration.seconds) s")
    for format in formats {
        print("  codec \(fourCC(CMFormatDescriptionGetMediaSubType(format)))")
        let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
        print("  extensions:\(describe(extensions))")
        let log = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_LogTransferFunction)
        print("  LogTransferFunction: \(log.map { "\($0)" } ?? "absent")")
    }

    let metadata = try await asset.load(.metadata)
    print("  file metadata:")
    for item in metadata {
        let value = try await item.load(.value)
        print("    \(item.identifier?.rawValue ?? "?") = \(value.map { "\($0)" } ?? "nil")")
    }
    for metadataTrack in try await asset.loadTracks(withMediaType: .metadata) {
        let descriptions = try await metadataTrack.load(.formatDescriptions)
        for description in descriptions {
            let identifiers = CMMetadataFormatDescriptionGetIdentifiers(description) as? [String] ?? []
            print("  timed metadata track \(metadataTrack.trackID): \(identifiers.joined(separator: ", "))")
        }
    }

    // Frame durations from the compressed samples (no decoding).
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    output.alwaysCopiesSampleData = false
    reader.add(output)
    guard reader.startReading() else { throw reader.error! }
    var durations: [String: Int] = [:]
    var count = 0
    var previous: CMTime?
    var gaps: [String] = []
    while let sample = output.copyNextSampleBuffer() {
        guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
        let pts = sample.presentationTimeStamp, duration = sample.duration
        durations["\(duration.value)/\(duration.timescale)", default: 0] += 1
        if let previous, pts - previous != duration, gaps.count < 12 {
            gaps.append(String(format: "frame %d at %.3f s: step %lld/%d", count, pts.seconds, (pts - previous).value, (pts - previous).timescale))
        }
        previous = pts
        count += 1
    }
    print("  frames \(count); durations \(durations.sorted { $0.value > $1.value }.map { "\($0.key)×\($0.value)" }.joined(separator: ", "))")
    if !gaps.isEmpty { print("  irregular steps: \(gaps.joined(separator: "; "))") }
}

for path in CommandLine.arguments.dropFirst() {
    try await probe(URL(fileURLWithPath: path))
}
