// Task 0 probe: what a custom AVVideoCompositing compositor receives, how fast, and with which code values.
// Throwaway; never writes to its inputs.
import AVFoundation
import QuartzCore
import VideoToolbox
import CoreVideo
import Darwin
import Foundation
import Metal

func fourCC(_ v: OSType) -> String {
    let b = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((v >> UInt32($0)) & 0xFF))) }
    return String(b)
}
func code(_ s: String) -> OSType { s.utf8.reduce(0) { ($0 << 8) | OSType($1) } }

func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

final class ProbeState: @unchecked Sendable {
    static let shared = ProbeState()
    let lock = NSLock()
    var sourceFormats: [OSType] = []
    var outputFormat: OSType = kCVPixelFormatType_64RGBAHalf
    var passthrough = true
    var received: [String: Int] = [:]
    var ioSurface = 0, frames = 0
    var attachments = ""
    var samples: [Int: [String]] = [:]   // frame index -> sample strings
    var sampleFrames: Set<Int> = []
    var peakFootprint = 0.0
    var touchMetal = false
    var device = MTLCreateSystemDefaultDevice()!
    lazy var cache: CVMetalTextureCache = {
        var c: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &c)
        return c!
    }()
}

/// Sample positions on a 3840x2160 (or scaled) frame: an 8x8 grid.
func grid(width: Int, height: Int) -> [(Int, Int)] {
    var p: [(Int, Int)] = []
    for gy in 0 ..< 8 { for gx in 0 ..< 8 { p.append(((gx * 2 + 1) * width / 16 & ~1, (gy * 2 + 1) * height / 16)) } }
    return p
}

func sampleBuffer(_ pb: CVPixelBuffer) -> [String] {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let f = CVPixelBufferGetPixelFormatType(pb)
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
    var out: [String] = []
    for (x, y) in grid(width: w, height: h) {
        switch f {
        case code("xf22"), code("x422"), code("xf20"), code("x420"):
            let yb = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt16.self)
            let ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0) / 2
            let cb = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt16.self)
            let cs = CVPixelBufferGetBytesPerRowOfPlane(pb, 1) / 2
            let cy = (f == code("xf22") || f == code("x422")) ? y : y / 2
            let Y = yb[y * ys + x] >> 6, U = cb[cy * cs + x] >> 6, V = cb[cy * cs + x + 1] >> 6
            out.append("\(Y),\(U),\(V)")
        case code("420v"), code("420f"):
            let yb = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
            let ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            let cb = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self)
            let cs = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
            out.append("\(yb[y * ys + x]),\(cb[(y / 2) * cs + x]),\(cb[(y / 2) * cs + x + 1])")
        case kCVPixelFormatType_64RGBAHalf:
            let b = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: Float16.self)
            let s = CVPixelBufferGetBytesPerRow(pb) / 2
            let i = y * s + x * 4
            out.append(String(format: "%.5f,%.5f,%.5f", Float(b[i]), Float(b[i + 1]), Float(b[i + 2])))
        case kCVPixelFormatType_32BGRA:
            let b = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
            let i = y * CVPixelBufferGetBytesPerRow(pb) + x * 4
            out.append("\(b[i + 2]),\(b[i + 1]),\(b[i])")
        default:
            out.append("?")
        }
    }
    return out
}

final class ProbeCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: ProbeState.shared.sourceFormats.map { NSNumber(value: $0) },
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: ProbeState.shared.outputFormat),
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }
    var supportsWideColorSourceFrames: Bool { true }
    var canConformColorOfSourceFrames: Bool { true }
    var context: AVVideoCompositionRenderContext?
    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) { context = newRenderContext }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        let st = ProbeState.shared
        guard let id = request.sourceTrackIDs.first?.int32Value, let src = request.sourceFrame(byTrackID: id) else {
            request.finish(with: NSError(domain: "probe", code: 1)); return
        }
        st.lock.lock()
        let f = fourCC(CVPixelBufferGetPixelFormatType(src))
        st.received[f, default: 0] += 1
        if CVPixelBufferGetIOSurface(src) != nil { st.ioSurface += 1 }
        let index = st.frames
        st.frames += 1
        if index == 0 {
            let keys = [kCVImageBufferYCbCrMatrixKey, kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey]
            st.attachments = keys.map { "\($0)=\(CVBufferCopyAttachment(src, $0, nil).map { "\($0)" } ?? "nil")" }.joined(separator: " ")
                + " size=\(CVPixelBufferGetWidth(src))x\(CVPixelBufferGetHeight(src))"
        }
        let wantsSample = st.sampleFrames.contains(index)
        let passthrough = st.passthrough, touch = st.touchMetal
        if index % 24 == 0 { st.peakFootprint = max(st.peakFootprint, footprintMB()) }
        st.lock.unlock()
        if wantsSample {
            let s = sampleBuffer(src)
            st.lock.lock(); st.samples[index] = s; st.lock.unlock()
        }
        if touch {
            // Wrap planes as Metal textures (zero copy) to prove the path works.
            var t: CVMetalTexture?
            let fmt: MTLPixelFormat = CVPixelBufferGetPlaneCount(src) > 0 ? .r16Unorm : .rgba16Float
            CVMetalTextureCacheCreateTextureFromImage(nil, st.cache, src, nil, fmt,
                CVPixelBufferGetWidthOfPlane(src, 0), CVPixelBufferGetHeightOfPlane(src, 0), 0, &t)
            if t == nil || CVMetalTextureGetTexture(t!) == nil { print("metal wrap failed for \(f)") }
        }
        if passthrough {
            request.finish(withComposedVideoFrame: src)
        } else {
            guard let out = context?.newPixelBuffer() else { request.finish(with: NSError(domain: "probe", code: 2)); return }
            if wantsSample {
                // Record the output format we were given.
                st.lock.lock(); st.samples[-1] = ["out=\(fourCC(CVPixelBufferGetPixelFormatType(out)))"]; st.lock.unlock()
            }
            request.finish(withComposedVideoFrame: out)
        }
    }
}

// MARK: - Runs

func makeComposition(_ url: URL, seconds: Double) async throws -> (AVMutableComposition, AVMutableVideoComposition) {
    let asset = AVURLAsset(url: url)
    let track = try await asset.loadTracks(withMediaType: .video).first!
    let (size, range, minFrame) = try await track.load(.naturalSize, .timeRange, .minFrameDuration)
    let comp = AVMutableComposition()
    comp.naturalSize = size
    let ct = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
    let dur = CMTimeMinimum(range.duration, CMTime(seconds: seconds, preferredTimescale: 24000))
    try ct.insertTimeRange(CMTimeRange(start: range.start, duration: dur), of: track, at: .zero)
    let vc = AVMutableVideoComposition()
    vc.customVideoCompositorClass = ProbeCompositor.self
    vc.frameDuration = minFrame
    vc.renderSize = size
    vc.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
    vc.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
    vc.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
    let ins = AVMutableVideoCompositionInstruction()
    ins.timeRange = CMTimeRange(start: .zero, duration: dur)
    ins.layerInstructions = [AVMutableVideoCompositionLayerInstruction(assetTrack: ct)]
    vc.instructions = [ins]
    return (comp, vc)
}

func runReader(_ url: URL, seconds: Double, label: String) async throws {
    let st = ProbeState.shared
    st.lock.lock(); st.received = [:]; st.ioSurface = 0; st.frames = 0; st.samples = [:]; st.peakFootprint = footprintMB(); st.lock.unlock()
    let before = footprintMB()
    let (comp, vc) = try await makeComposition(url, seconds: seconds)
    let reader = try AVAssetReader(asset: comp)
    let tracks = try await comp.loadTracks(withMediaType: .video)
    let output = AVAssetReaderVideoCompositionOutput(videoTracks: tracks, videoSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: st.passthrough ? st.sourceFormats[0] : st.outputFormat)
    ])
    output.videoComposition = vc
    output.alwaysCopiesSampleData = false
    reader.add(output)
    let t0 = Date()
    guard reader.startReading() else { print("\(label): startReading failed \(String(describing: reader.error))"); return }
    var n = 0
    var outFormat = ""
    while let sb = output.copyNextSampleBuffer() {
        if n == 0, let pb = CMSampleBufferGetImageBuffer(sb) { outFormat = fourCC(CVPixelBufferGetPixelFormatType(pb)) }
        n += 1
    }
    let dt = Date().timeIntervalSince(t0)
    if reader.status == .failed { print("\(label): FAILED \(String(describing: reader.error))") }
    st.lock.lock()
    let line = String(format: "%@ | frames %d | %.1f fps | received %@ | ioSurface %d/%d | readerOut %@ | footprint %.0f→peak %.0f MB",
        label, n, Double(n) / dt, st.received.map { "\($0.key)×\($0.value)" }.joined(separator: ","),
        st.ioSurface, st.frames, outFormat, before, st.peakFootprint)
    print(line)
    print("   attachments: \(st.attachments)")
    for k in st.samples.keys.sorted() { print("   sample[\(k)]: \(st.samples[k]!.joined(separator: " "))") }
    st.lock.unlock()
}

let args = CommandLine.arguments
let url = URL(fileURLWithPath: args[1])
let seconds = Double(args[2]) ?? 10
let formats = args[3].split(separator: ",").map { $0 == "RGhA" ? kCVPixelFormatType_64RGBAHalf : code(String($0)) }
let mode = args.count > 4 ? args[4] : "pass"
let st = ProbeState.shared
st.sourceFormats = formats
st.passthrough = mode == "pass" || mode == "touch"
st.touchMetal = mode == "touch"
if mode.hasPrefix("write:") || mode == "player" { st.passthrough = false; st.outputFormat = args.count > 7 && args[7] == "RGhA" ? kCVPixelFormatType_64RGBAHalf : code("x422") }
if mode.hasPrefix("out:") { st.outputFormat = mode == "out:RGhA" ? kCVPixelFormatType_64RGBAHalf : code(String(mode.dropFirst(4))) }
st.sampleFrames = args.count > 5 ? Set(args[5].split(separator: ",").compactMap { Int($0) }) : []
func runWriter(_ url: URL, seconds: Double, codec: String) async throws {
    let st = ProbeState.shared
    let (comp, vc) = try await makeComposition(url, seconds: seconds)
    let reader = try AVAssetReader(asset: comp)
    let tracks = try await comp.loadTracks(withMediaType: .video)
    let output = AVAssetReaderVideoCompositionOutput(videoTracks: tracks, videoSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: st.outputFormat)])
    output.videoComposition = vc
    output.alwaysCopiesSampleData = false
    reader.add(output)
    let dst = URL(fileURLWithPath: CommandLine.arguments[6])
    try? FileManager.default.removeItem(at: dst)
    let writer = try AVAssetWriter(outputURL: dst, fileType: .mov)
    var settings: [String: Any] = [AVVideoWidthKey: 3840, AVVideoHeightKey: 2160,
        AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]]
    if codec == "hevc10" {
        settings[AVVideoCodecKey] = AVVideoCodecType.hevc
        settings[AVVideoCompressionPropertiesKey] = [AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String]
    } else { settings[AVVideoCodecKey] = AVVideoCodecType.proRes422HQ }
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    writer.add(input)
    reader.startReading(); writer.startWriting(); writer.startSession(atSourceTime: .zero)
    let t0 = Date(); var n = 0
    while let sb = output.copyNextSampleBuffer() {
        while !input.isReadyForMoreMediaData { usleep(500) }
        if !input.append(sb) { print("append failed \(String(describing: writer.error))"); break }
        n += 1
    }
    input.markAsFinished(); await writer.finishWriting()
    print(String(format: "write %@ out=%@ frames %d %.1f fps status %d err %@", codec, fourCC(st.outputFormat), n, Double(n) / Date().timeIntervalSince(t0), writer.status.rawValue, String(describing: writer.error)))
}

func runPlayer(_ url: URL, seconds: Double) async throws {
    let st = ProbeState.shared
    let (comp, vc) = try await makeComposition(url, seconds: seconds)
    let item = AVPlayerItem(asset: comp)
    item.videoComposition = vc
    let vo = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
    item.add(vo)
    let player = AVPlayer(playerItem: item)
    player.isMuted = true
    while item.status != .readyToPlay { try await Task.sleep(for: .milliseconds(50)); if item.status == .failed { print("player failed \(String(describing: item.error))"); return } }
    player.play()
    var got = 0, fmt = ""
    let t0 = Date()
    while Date().timeIntervalSince(t0) < seconds {
        let t = vo.itemTime(forHostTime: CACurrentMediaTime())
        if vo.hasNewPixelBuffer(forItemTime: t), let pb = vo.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) {
            got += 1; fmt = fourCC(CVPixelBufferGetPixelFormatType(pb))
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    let log = item.accessLog()?.events.last
    st.lock.lock()
    print("player: compositor frames \(st.frames) received \(st.received) videoOutput frames \(got) fmt \(fmt) dropped \(log?.numberOfDroppedVideoFrames ?? -1) time \(player.currentTime().seconds)")
    st.lock.unlock()
}

let sem = DispatchSemaphore(value: 0)
Task {
    if mode.hasPrefix("write:") { do { try await runWriter(url, seconds: seconds, codec: String(mode.dropFirst(6))) } catch { print("error \(error)") }; sem.signal(); return }
    if mode == "player" { do { try await runPlayer(url, seconds: seconds) } catch { print("error \(error)") }; sem.signal(); return }
    do { try await runReader(url, seconds: seconds, label: "\(url.lastPathComponent) src=\(args[3]) mode=\(mode)") } catch { print("error \(error)") }
    sem.signal()
}
while sem.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
