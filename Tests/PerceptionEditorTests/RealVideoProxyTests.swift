@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import PerceptionEditor

/// Run with PME_VIDEO_SAMPLE=/Volumes/ExSSD1/Pictures/110_PANA/P1107157.MOV and
/// PME_VLOG_SHORT=/Volumes/ExSSD1/Pictures/110_PANA/P1107158.MOV (full-range V-Log) on the target M1.
struct RealVideoProxyTests {
    /// Gate G2 (proxy part): a V-Log proxy must look like its original. Version-1 proxies were about
    /// 17% brighter because AVFoundation's full-to-video-range conversion only added 64 to luma.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PME_VLOG_SHORT"] != nil))
    func lumixVLogProxyKeepsTheOriginalsLevels() async throws {
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PME_VLOG_SHORT"]!)
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let temp = try TempDirectory()
        let proxy = temp.url.appendingPathComponent("proxy.mov")
        _ = try await ProxyGenerator.generate(source: source, destination: proxy)

        let original = try await decodedRGBCellMeans(source)
        let proxied = try await decodedRGBCellMeans(proxy)
        let worst = zip(original, proxied).map { abs($0 - $1).max() }.max() ?? .infinity
        print("V-Log proxy cell-mean difference: \(worst * 1023) of 1023 levels")
        #expect(worst <= 4.0 / 1023, "Proxy cell means differ from the original by \(worst * 1023) levels")
        let after = try FileManager.default.attributesOfItem(atPath: source.path)
        #expect(after[.size] as? Int == attributes[.size] as? Int)
        #expect(after[.modificationDate] as? Date == attributes[.modificationDate] as? Date, "The original must never change")
    }

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
