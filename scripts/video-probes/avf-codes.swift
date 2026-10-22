// Gates G10/G11: writes one frame's 10-bit 4:2:2 codes exactly as AVFoundation decodes them (what the
// compositor receives) as planar yuv422p10le, for references built from the app's own input. ffmpeg's
// ProRes decoder rounds ProRes's 12-bit samples to 10 bits differently (up to 1 code), which a log
// LUT magnifies. Opens the clip read-only.
//
//   SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swiftc -O scripts/video-probes/avf-codes.swift -o "$TMPDIR/avf-codes"
//   "$TMPDIR/avf-codes" <clip.mov> <out.yuv> [frame] [full|limited]
import AVFoundation
import CoreVideo
import Foundation

let arguments = CommandLine.arguments
let clip = URL(fileURLWithPath: arguments[1]), output = URL(fileURLWithPath: arguments[2])
let wanted = arguments.count > 3 ? Int(arguments[3])! : 0
let full = arguments.count > 4 && arguments[4] == "full"
let asset = AVURLAsset(url: clip)
let track = try await asset.loadTracks(withMediaType: .video).first!
let reader = try AVAssetReader(asset: asset)
let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
    kCVPixelBufferPixelFormatTypeKey as String: full ? kCVPixelFormatType_422YpCbCr10BiPlanarFullRange : kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
])
reader.add(trackOutput)
reader.startReading()
var index = 0
var frame: CVPixelBuffer?
while let sample = trackOutput.copyNextSampleBuffer() {
    if index == wanted { frame = CMSampleBufferGetImageBuffer(sample); break }
    index += 1
}
reader.cancelReading()
guard let buffer = frame else { fatalError("frame \(wanted) not found") }
CVPixelBufferLockBaseAddress(buffer, .readOnly)
let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
var y = [UInt16](), cb = [UInt16](), cr = [UInt16]()
y.reserveCapacity(width * height); cb.reserveCapacity(width * height / 2); cr.reserveCapacity(width * height / 2)
let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!, chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!
let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0), chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
for row in 0 ..< height {
    let l = luma.advanced(by: row * lumaStride).assumingMemoryBound(to: UInt16.self)
    let c = chroma.advanced(by: row * chromaStride).assumingMemoryBound(to: UInt16.self)
    for x in 0 ..< width { y.append(l[x] >> 6) }
    for x in 0 ..< width / 2 { cb.append(c[x * 2] >> 6); cr.append(c[x * 2 + 1] >> 6) }
}
CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
let data = (y + cb + cr).withUnsafeBufferPointer { Data(buffer: $0) }
try data.write(to: output)
print("frame \(wanted): \(width)x\(height) codes written to \(output.path)")
