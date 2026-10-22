// Task 13.0 probe: does a custom compositor receive an Apple Log clip's Y'CbCr code values
// unchanged, with the composition's color properties at Rec. 709 and at BT.2020? And which source
// frame does each composition time get? Opens the clip read-only; writes only to the output folder.
//
// For each composition setting it records the pixel format the compositor receives, whether it is
// IOSurface-backed, and the 10-bit codes at an 8×8 grid of positions for composition frames
// `frames` (Y at (x, y); Cb, Cr at (x/2, y)). Frames are identified by decode index by matching
// those codes against every frame read straight from the track (no composition).
//
// Usage: applelogcodes <clip.mov> <output folder> [frame,frame,...]
// Writes <output>/codes_<setting>_<frame>.txt and <output>/track_<frame>.txt (one "y,cb,cr" per position).
import AVFoundation
import CoreVideo
import Foundation

func fourCC(_ value: OSType) -> String {
    String([24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((value >> UInt32($0)) & 0xFF))) })
}
func code(_ text: String) -> OSType { text.utf8.reduce(0) { ($0 << 8) | OSType($1) } }

let grid = 8
func positions(width: Int, height: Int) -> [(Int, Int)] {
    (0 ..< grid).flatMap { row in (0 ..< grid).map { column in
        (((column * 2 + 1) * width / (grid * 2)) & ~1, (row * 2 + 1) * height / (grid * 2))
    } }
}

/// 10-bit codes at the grid from a bi-planar 4:2:2 or 4:2:0 buffer (8- or 16-bit samples).
func samples(_ buffer: CVPixelBuffer) -> [(Int, Int, Int)] {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let format = CVPixelBufferGetPixelFormatType(buffer)
    let tenBit = [code("xf22"), code("x422"), code("xf20"), code("x420")].contains(format)
    let subY = [code("420v"), code("420f"), code("xf20"), code("x420")].contains(format) ? 2 : 1
    let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
    let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!, chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!
    let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0), chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
    func read(_ base: UnsafeMutableRawPointer, _ stride: Int, _ index: Int, _ row: Int) -> Int {
        tenBit ? Int(base.advanced(by: row * stride).assumingMemoryBound(to: UInt16.self)[index] >> 6)
               : Int(base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self)[index]) << 2
    }
    return positions(width: width, height: height).map { x, y in
        (read(lumaBase, lumaStride, x, y), read(chromaBase, chromaStride, x, y / subY), read(chromaBase, chromaStride, x + 1, y / subY))
    }
}

final class Recorder: @unchecked Sendable {
    static let shared = Recorder()
    let lock = NSLock()
    var formats: [String: Int] = [:]
    var ioSurface = true
    var wanted: Set<Int> = []
    var codes: [Int: [(Int, Int, Int)]] = [:]
    var frameSeconds = 1.0 / 24
}

final class ProbeCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: [code("xf22"), code("x422"), code("420v"), code("420f")],
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: code("x422")]
    }
    var supportsWideColorSourceFrames: Bool { true }
    var canConformColorOfSourceFrames: Bool { true }
    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        let trackID = request.sourceTrackIDs.first!.int32Value
        guard let source = request.sourceFrame(byTrackID: trackID) else { return request.finish(with: CocoaError(.fileReadUnknown)) }
        let recorder = Recorder.shared
        let frame = Int((request.compositionTime.seconds / recorder.frameSeconds).rounded())
        recorder.lock.withLock {
            recorder.formats[fourCC(CVPixelBufferGetPixelFormatType(source)), default: 0] += 1
            if CVPixelBufferGetIOSurface(source) == nil { recorder.ioSurface = false }
        }
        if recorder.lock.withLock({ recorder.wanted.contains(frame) }) {
            let codes = samples(source)
            recorder.lock.withLock { recorder.codes[frame] = codes }
        }
        request.finish(withComposedVideoFrame: request.renderContext.newPixelBuffer()!)
    }
}

func write(_ codes: [(Int, Int, Int)], to url: URL) throws {
    try codes.map { "\($0.0),\($0.1),\($0.2)" }.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
}

let arguments = CommandLine.arguments
let clip = URL(fileURLWithPath: arguments[1]), outputFolder = URL(fileURLWithPath: arguments[2])
let frames = arguments.count > 3 ? arguments[3].split(separator: ",").map { Int($0)! } : [0, 100, 200]
let asset = AVURLAsset(url: clip)
let track = try await asset.loadTracks(withMediaType: .video).first!
let (size, timeRange) = try await track.load(.naturalSize, .timeRange)

// Every frame straight from the track, by decode index, for identifying frames.
var trackCodes: [[(Int, Int, Int)]] = []
do {
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: code("x422")])
    output.alwaysCopiesSampleData = false
    reader.add(output)
    reader.startReading()
    while let sample = output.copyNextSampleBuffer() {
        if let buffer = CMSampleBufferGetImageBuffer(sample) { trackCodes.append(samples(buffer)) }
    }
    for frame in frames where frame < trackCodes.count { try write(trackCodes[frame], to: outputFolder.appendingPathComponent("track_\(frame).txt")) }
    print("track: \(trackCodes.count) frames read as x422 (no composition)")
}

func identify(_ codes: [(Int, Int, Int)]) -> Int? {
    trackCodes.firstIndex { candidate in zip(candidate, codes).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 && $0.2 == $1.2 } }
}

for (label, primaries, matrix) in [("709", AVVideoColorPrimaries_ITU_R_709_2, AVVideoYCbCrMatrix_ITU_R_709_2),
                                   ("2020", AVVideoColorPrimaries_ITU_R_2020, AVVideoYCbCrMatrix_ITU_R_2020)] {
    let composition = AVMutableComposition()
    let compositionTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
    try compositionTrack.insertTimeRange(timeRange, of: track, at: .zero)
    let videoComposition = AVMutableVideoComposition()
    videoComposition.customVideoCompositorClass = ProbeCompositor.self
    videoComposition.frameDuration = CMTime(value: 1000, timescale: 24000)
    videoComposition.renderSize = size
    videoComposition.colorPrimaries = primaries
    videoComposition.colorYCbCrMatrix = matrix
    videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
    let instruction = AVMutableVideoCompositionInstruction()
    instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
    instruction.layerInstructions = [AVMutableVideoCompositionLayerInstruction(assetTrack: compositionTrack)]
    videoComposition.instructions = [instruction]

    let recorder = Recorder.shared
    recorder.lock.withLock { recorder.formats = [:]; recorder.ioSurface = true; recorder.codes = [:]; recorder.wanted = Set(frames) }
    let reader = try AVAssetReader(asset: composition)
    let output = AVAssetReaderVideoCompositionOutput(videoTracks: [compositionTrack], videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: code("x422")])
    output.videoComposition = videoComposition
    reader.add(output)
    reader.startReading()
    let start = Date()
    var count = 0
    while output.copyNextSampleBuffer() != nil { count += 1 }
    let seconds = Date().timeIntervalSince(start)
    let (formats, surface, codes) = recorder.lock.withLock { (recorder.formats, recorder.ioSurface, recorder.codes) }
    print("composition \(label): \(count) frames in \(String(format: "%.1f", seconds)) s (\(String(format: "%.1f", Double(count) / seconds)) fps, pass-through); source formats \(formats), IOSurface \(surface)")
    for frame in frames {
        guard let sampled = codes[frame] else { print("  frame \(frame): not rendered"); continue }
        try write(sampled, to: outputFolder.appendingPathComponent("codes_\(label)_\(frame).txt"))
        let match = identify(sampled)
        let reference = frame < trackCodes.count ? trackCodes[frame] : []
        let worst = zip(sampled, reference).map { max(abs($0.0 - $1.0), abs($0.1 - $1.1), abs($0.2 - $1.2)) }.max() ?? -1
        print("  composition frame \(frame): source decode index \(match.map(String.init) ?? "none (codes differ from every track frame)"), worst code difference to track frame \(frame): \(worst)")
    }
}
