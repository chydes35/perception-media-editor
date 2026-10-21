// Isolated research executable. Diagnostic SDR output is NOT a delivery pipeline.
@preconcurrency import AVFoundation
import CoreImage
import Vision
import Foundation
import Darwin

struct ProbeError: Error, CustomStringConvertible { var description: String }
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw ProbeError(description: message) }
}

struct MemoryReading: Codable {
    var footprintMiB: Double
    var residentMiB: Double
    var compressedMiB: Double
    static func read() -> MemoryReading {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return MemoryReading(footprintMiB: -1, residentMiB: -1, compressedMiB: -1) }
        let mib = 1048576.0
        return MemoryReading(footprintMiB: Double(info.phys_footprint) / mib,
                             residentMiB: Double(info.resident_size) / mib,
                             compressedMiB: Double(info.compressed) / mib)
    }
}

final class FrameReader {
    let reader: AVAssetReader
    let output: AVAssetReaderTrackOutput
    let orientation: CGAffineTransform
    let width: Int
    let height: Int
    let context: CIContext

    init(url: URL, start: Double, duration: Double, edge: Int) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ProbeError(description: "No video track")
        }
        orientation = try await track.load(.preferredTransform)
        let size = try await track.load(.naturalSize)
        let extent = CGRect(origin: .zero, size: size).applying(orientation)
        let scale = min(1, Double(edge) / max(extent.width, extent.height))
        width = max(2, Int(extent.width * scale) / 2 * 2)
        height = max(2, Int(extent.height * scale) / 2 * 2)
        context = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 60000),
                                       duration: CMTime(seconds: duration, preferredTimescale: 60000))
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.alwaysCopiesSampleData = false
        try require(reader.canAdd(output), "Cannot add video decoder")
        reader.add(output)
        try require(reader.startReading(), "Decoder start: \(String(describing: reader.error))")
    }

    func next() throws -> (CVPixelBuffer, CMTime)? {
        try Task.checkCancellation()
        return try autoreleasepool {
            guard let sample = output.copyNextSampleBuffer() else {
                try require(reader.status != .failed, "Decode failed: \(String(describing: reader.error))")
                return nil
            }
            guard let source = CMSampleBufferGetImageBuffer(sample) else {
                throw ProbeError(description: "Decoded sample has no image buffer")
            }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            try require(pts.isValid && pts.isNumeric, "Invalid source PTS")
            let oriented = CIImage(cvPixelBuffer: source).transformed(by: orientation)
            let normalized = oriented.transformed(by: CGAffineTransform(translationX: -oriented.extent.minX,
                                                                          y: -oriented.extent.minY))
            let image = normalized.transformed(by: CGAffineTransform(scaleX: Double(width) / normalized.extent.width,
                                                                       y: Double(height) / normalized.extent.height))
            let destination = try makeBuffer(width: width, height: height)
            context.render(image, to: destination, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            return (destination, pts)
        }
    }
    deinit { reader.cancelReading(); context.clearCaches() }
}

func makeBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
    var result: CVPixelBuffer?
    let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                    [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &result)
    guard status == kCVReturnSuccess, let result else { throw ProbeError(description: "Pixel allocation failed") }
    return result
}

struct Registration {
    var delta: Pose
    var confidence: Float
    var valid: Bool
}

func estimate(previous: CVPixelBuffer, current: CVPixelBuffer, homography: Bool) throws -> Registration {
    let handler = VNImageRequestHandler(cvPixelBuffer: previous, options: [:])
    if homography {
        let request = VNHomographicImageRegistrationRequest(targetedCVPixelBuffer: current, options: [:])
        try handler.perform([request])
        guard let result = request.results?.first else { return Registration(delta: Pose(), confidence: 0, valid: false) }
        let h = result.warpTransform
        let w = Double(CVPixelBufferGetWidth(current)), ht = Double(CVPixelBufferGetHeight(current))
        // Project the observation to rigid center displacement and rotation. Never warp perspective.
        let cx = Float(w / 2), cy = Float(ht / 2)
        let z = h[0,2] * cx + h[1,2] * cy + h[2,2]
        let x = Double((h[0,0] * cx + h[1,0] * cy + h[2,0]) / z) - w / 2
        let y = Double((h[0,1] * cx + h[1,1] * cy + h[2,1]) / z) - ht / 2
        let angle = Double(atan2(h[0,1], h[0,0]))
        let perspective = abs(h[0,2]) * Float(w) + abs(h[1,2]) * Float(ht)
        let scale = hypot(h[0,0], h[0,1])
        let valid = z.isFinite && abs(z) > 0.1 && perspective < 0.1 && abs(scale - 1) < 0.1
        return Registration(delta: Pose(x: -x, y: -y, angle: -angle), confidence: result.confidence, valid: valid)
    }
    let request = VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: current, options: [:])
    try handler.perform([request])
    guard let result = request.results?.first else { return Registration(delta: Pose(), confidence: 0, valid: false) }
    let t = result.alignmentTransform
    // Vision aligns the floating/current frame onto the reference/previous frame.
    return Registration(delta: Pose(x: -t.tx, y: -t.ty), confidence: result.confidence, valid: true)
}

struct ProbeReport: Codable {
    var input: String
    var model: String
    var diagnosticColor = "8-bit BGRA/sRGB analysis; H.264 SDR diagnostic only. No log/HDR/10-bit preservation claim."
    var width: Int
    var height: Int
    var analysisSeconds: Double
    var renderSeconds: Double
    var initialMemory: MemoryReading
    var peakSampledMemory: MemoryReading
    var requiredZoom: Double
    var appliedZoom: Double
    var appliedStrength: Double
    var removedDimensionFraction: Double
    var rejected: Int
    var registrationErrors: Int
    var samples: [MotionSample]
    var corrections: [Pose]
}

func analyze(url: URL, mode: String, start: Double, duration: Double, edge: Int) async throws -> ProbeReport {
    let initialMemory = MemoryReading.read()
    var peak = initialMemory
    let began = Date()
    let reader = try await FrameReader(url: url, start: start, duration: duration, edge: edge)
    var previous: CVPixelBuffer?
    var samples: [MotionSample] = []
    var path = Pose(), segment = 0, rejected = 0, errors = 0
    while let (current, pts) = try reader.next() {
        if let last = samples.last {
            try require(CMTimeCompare(pts, CMTime(value: last.value, timescale: last.timescale)) > 0,
                        "Non-increasing source PTS")
        }
        var confidence: Float = 1
        var valid = true
        if let previous, mode != "none" {
            let observation: Registration
            do { observation = try autoreleasepool { try estimate(previous: previous, current: current, homography: mode == "homography") } }
            catch { observation = Registration(delta: Pose(), confidence: 0, valid: false); errors += 1 }
            let d = observation.delta
            let dt = pts.seconds - (samples.last?.seconds ?? pts.seconds)
            valid = observation.valid && observation.confidence >= 0.1 && dt < 0.25
                && [d.x, d.y, d.angle].allSatisfy(\.isFinite)
                && abs(d.x) < Double(reader.width) * 0.15 && abs(d.y) < Double(reader.height) * 0.15
                && abs(d.angle) < 0.10
            confidence = observation.confidence
            if valid { path.x += d.x; path.y += d.y; path.angle += d.angle }
            else { segment += 1; path = Pose(); rejected += 1 }
        }
        samples.append(MotionSample(value: pts.value, timescale: pts.timescale, segment: segment,
                                    path: path, confidence: confidence, valid: valid))
        previous = current
        let memory = MemoryReading.read()
        peak.footprintMiB = max(peak.footprintMiB, memory.footprintMiB)
        peak.residentMiB = max(peak.residentMiB, memory.residentMiB)
        peak.compressedMiB = max(peak.compressedMiB, memory.compressedMiB)
    }
    try require(samples.count >= 3, "Fewer than three decoded frames")
    let full = MotionMath.corrections(samples, radius: 0.5, strength: 1)
    let w = Double(reader.width), h = Double(reader.height)
    let required = MotionMath.requiredZoom(full, width: w, height: h)
    var strength = 1.0
    // One constant crop for the clip. Scale corrections down if the budget is exceeded.
    if required > 1 / 0.85 {
        var low = 0.0, high = 1.0
        for _ in 0..<32 {
            let mid = (low + high) / 2
            let poses = full.map { Pose(x: $0.x * mid, y: $0.y * mid, angle: $0.angle * mid) }
            if MotionMath.requiredZoom(poses, width: w, height: h) <= 1 / 0.85 { low = mid } else { high = mid }
        }
        strength = low
    }
    let corrections = full.map { Pose(x: $0.x * strength, y: $0.y * strength, angle: $0.angle * strength) }
    let zoom = MotionMath.requiredZoom(corrections, width: w, height: h)
    return ProbeReport(input: url.path, model: mode, width: reader.width, height: reader.height,
                       analysisSeconds: Date().timeIntervalSince(began), renderSeconds: 0,
                       initialMemory: initialMemory, peakSampledMemory: peak,
                       requiredZoom: required, appliedZoom: zoom, appliedStrength: strength,
                       removedDimensionFraction: 1 - 1 / zoom, rejected: rejected,
                       registrationErrors: errors, samples: samples, corrections: corrections)
}

func render(url: URL, destination: URL, report: ProbeReport, start: Double, duration: Double, edge: Int) async throws -> Double {
    let began = Date()
    let reader = try await FrameReader(url: url, start: start, duration: duration, edge: edge)
    let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: reader.width, AVVideoHeightKey: reader.height,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000],
        AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                   AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                   AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
    ])
    let sourceScale = report.samples[0].timescale
    try require(sourceScale > 0 && report.samples.allSatisfy { $0.timescale == sourceScale },
                "Diagnostic rendering requires a consistent source timebase")
    input.mediaTimeScale = sourceScale
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: reader.width, kCVPixelBufferHeightKey as String: reader.height
    ])
    try require(writer.canAdd(input), "Cannot add diagnostic encoder")
    writer.add(input)
    try require(writer.startWriting(), "Encoder start failed")
    writer.startSession(atSourceTime: .zero)
    var index = 0
    var first: CMTime?
    while let (buffer, pts) = try reader.next() {
        try require(index < report.samples.count, "Render/analysis count mismatch")
        let sample = report.samples[index]
        try require(CMTimeCompare(pts, CMTime(value: sample.value, timescale: sample.timescale)) == 0,
                    "Render/analysis source PTS mismatch")
        if first == nil { first = pts }
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            try require(writer.status == .writing, "Encoder failed: \(String(describing: writer.error))")
            try await Task.sleep(for: .milliseconds(2))
        }
        try autoreleasepool {
            let output = try makeBuffer(width: reader.width, height: reader.height)
            let transform = MotionMath.transform(report.corrections[index], width: Double(reader.width),
                                                  height: Double(reader.height), zoom: report.appliedZoom)
            let image = CIImage(cvPixelBuffer: buffer).transformed(by: transform)
            reader.context.render(image, to: output, bounds: CGRect(x: 0, y: 0, width: reader.width, height: reader.height),
                                  colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            try require(adaptor.append(output, withPresentationTime: CMTimeSubtract(pts, first!)), "Encode append failed")
        }
        index += 1
    }
    try require(index == report.samples.count, "Render lost frames")
    input.markAsFinished()
    await writer.finishWriting()
    try require(writer.status == .completed, "Encoder completion: \(String(describing: writer.error))")
    return Date().timeIntervalSince(began)
}

@main struct Probe {
    static func main() async {
        do {
            let args = CommandLine.arguments
            try require(args.count == 8, "Usage: probe INPUT NEW_OUTPUT_DIR none|translation|homography START_SECONDS DURATION_SECONDS LONG_EDGE render|analyze")
            guard let start = Double(args[4]), let duration = Double(args[5]), let edge = Int(args[6]) else {
                throw ProbeError(description: "Invalid numeric argument")
            }
            try require(start.isFinite && start >= 0 && duration.isFinite && duration > 0 && duration <= 180,
                        "Duration must be in (0,180] seconds; start must be nonnegative")
            try require(edge >= 64 && edge <= 960 && ["none", "translation", "homography"].contains(args[3])
                        && ["render", "analyze"].contains(args[7]), "Unsupported probe configuration")
            let url = URL(fileURLWithPath: args[1]).standardizedFileURL.resolvingSymlinksInPath()
            let directory = URL(fileURLWithPath: args[2]).standardizedFileURL
            // mkdir is exclusive, including against symlinks; never open an existing output tree.
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let mode = args[3], shouldRender = args[7] == "render"
            let result = try await Task.detached(priority: .utility) {
                var report = try await analyze(url: url, mode: mode, start: start, duration: duration, edge: edge)
                if shouldRender {
                    report.renderSeconds = try await render(url: url, destination: directory.appendingPathComponent("diagnostic.mov"),
                                                            report: report, start: start, duration: duration, edge: edge)
                }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(report).write(to: directory.appendingPathComponent("motion.json"), options: .atomic)
                return "\(mode): \(report.samples.count) frames; analysis \(report.analysisSeconds)s, render \(report.renderSeconds)s; peak sampled physical footprint \(report.peakSampledMemory.footprintMiB) MiB; crop \(100 * report.removedDimensionFraction)%; rejected \(report.rejected)"
            }.value
            print(result)
        } catch {
            // On failure the new directory may contain incomplete diagnostic output;
            // motion.json is published only after the encoder completes successfully.
            fputs("Probe failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
