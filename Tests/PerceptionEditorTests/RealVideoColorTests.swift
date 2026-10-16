@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import PerceptionEditor

/// Source color detection on real Lumix S5 files. Run with
/// PME_VLOG_SHORT=/Volumes/ExSSD1/Pictures/110_PANA/P1107158.MOV (V-Log, tagged BT.709) and
/// PME_REC709_8BIT=/Volumes/ExSSD1/Pictures/110_PANA/P1107172.MOV (standard gamma, 8-bit).
@MainActor
struct RealVideoColorTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PME_VLOG_SHORT"] != nil))
    func lumixVLogIsDetectedDespiteItsBT709Tags() async throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PME_VLOG_SHORT"]!)
        let color = try #require(await VideoMediaService.shared.metadata(for: url).sourceColor)
        print("V-Log sample: \(color.summary)")
        #expect(color.transfer == .vLog && color.gamut == .vGamut && color.detectedFrom == .panasonicMetadata)
        #expect(color.range == .full && color.matrix == .rec709 && color.bitDepth == 10 && color.chroma == .yuv422)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PME_REC709_8BIT"] != nil))
    func lumixStandardGammaStaysRec709() async throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PME_REC709_8BIT"]!)
        let color = try #require(await VideoMediaService.shared.metadata(for: url).sourceColor)
        print("Standard sample: \(color.summary)")
        #expect(color.transfer == .rec709 && color.gamut == .rec709 && !color.isLog)
        #expect(color.range == .video && color.bitDepth == 8 && color.chroma == .yuv420 && color.detectedFrom == .panasonicMetadata)
    }
}
