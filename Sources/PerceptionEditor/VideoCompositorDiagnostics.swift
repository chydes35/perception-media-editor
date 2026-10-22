import Foundation
import OSLog

/// Timing for the video compositor. Signposts ("VideoCompositor" intervals per frame, and a "GPU"
/// event with each frame's GPU time) are always emitted and cost nothing unless Instruments records
/// them. Log lines are opt-in, like `PhotoPreviewDiagnostics`: set `PME_VIDEO_DIAGNOSTICS=1`, or
/// `PerceptionVideoDiagnostics` in the bundle for QA builds. Only times and counts are logged.
enum VideoCompositorDiagnostics {
    static let enabled = ProcessInfo.processInfo.environment["PME_VIDEO_DIAGNOSTICS"] == "1"
        || Bundle.main.object(forInfoDictionaryKey: "PerceptionVideoDiagnostics") as? Bool == true
    static let signposter = OSSignposter(subsystem: "com.perceptionmedia.editor", category: "VideoCompositor")
    private static let logger = Logger(subsystem: "com.perceptionmedia.editor", category: "VideoCompositor")

    static func record(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let text = message()
        logger.info("\(text, privacy: .public)")
    }
}
