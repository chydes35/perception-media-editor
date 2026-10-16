@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import PerceptionEditor

/// Run with PME_VIDEO_SAMPLE=/Volumes/ExSSD1/Pictures/110_PANA/P1107157.MOV on the target M1.
struct RealVideoProxyTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PME_VIDEO_SAMPLE"] != nil))
    func lumixProxyIsFasterThanRealtimeAndFrameExact() async throws {
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PME_VIDEO_SAMPLE"]!)
        let temp = try TempDirectory()
        let trimmed = temp.url.appendingPathComponent("sample.mov")
        // Ten seconds keeps the gate short; copy by passthrough export, never touch the original.
        let export = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetPassthrough)!
        export.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 10, preferredTimescale: 24000))
        try await export.export(to: trimmed, as: .mov)

        let clock = ContinuousClock()
        let start = clock.now
        let info = try await ProxyGenerator.generate(source: trimmed, destination: temp.url.appendingPathComponent("proxy.mov"))
        let elapsed = (clock.now - start).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        let fps = Double(info.frameCount) / seconds
        print("Proxy: \(info.frameCount) frames, \(String(format: "%.1f", fps)) fps, \(info.pixelWidth)x\(info.pixelHeight)")
        #expect(info.frameCount == (try await ProxyGenerator.frameCount(at: trimmed)))
        #expect(fps >= 28.8, "Generation must stay at or above 1.2x realtime for 23.976 fps footage")
    }
}
