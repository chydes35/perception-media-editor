import Foundation
import OSLog

/// Local, opt-in metadata only. No paths, pixels or saved-project fields are logged.
/// The bundle flag is for isolated QA candidates; normal builds leave tracing disabled.
enum PhotoPreviewDiagnostics {
    static let enabled = ProcessInfo.processInfo.environment["PME_PREVIEW_DIAGNOSTICS"] == "1"
        || Bundle.main.object(forInfoDictionaryKey: "PerceptionPreviewDiagnostics") as? Bool == true
    private static let logger = Logger(subsystem: "com.perceptionmedia.editor", category: "PhotoPreview")

    static func record(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let text = message()
        logger.info("\(text, privacy: .public)")
    }
}
