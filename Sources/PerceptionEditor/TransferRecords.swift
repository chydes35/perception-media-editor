import Foundation

enum TransferItemPhase: String, Codable, Sendable {
    case queued       // not rendered yet
    case rendered     // staged, hashed, waiting to upload or to be acknowledged
    case processing   // server has the bytes and is making the private preview
    case ready        // server preview ready; staged file removed
    case failed
}

enum TransferStatus: String, Codable, Sendable {
    case running, paused, cancelled, completed
}

/// One photo in a transfer. `adjustments` is a copy taken when the user pressed Send, so
/// editing or switching projects afterwards cannot change what is being delivered.
struct TransferItemRecord: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var position: Int
    var sourcePath: String
    var adjustments: PhotoAdjustments
    var displayName: String
    var uploadFileName: String
    var stagedPath: String?
    var sizeBytes: Int?
    var sha256: String?
    var remoteItemID: String?
    var mediaID: String?
    /// Set before the first PUT. If a run is interrupted afterwards, the next run asks the
    /// server to verify the object before uploading again.
    var putStarted = false
    var phase: TransferItemPhase = .queued
    var message: String?
}

struct TransferCounts: Equatable, Sendable {
    var queued = 0
    var rendered = 0
    var processing = 0
    var ready = 0
    var failed = 0
    var total: Int { queued + rendered + processing + ready + failed }
}

struct TransferRecord: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var serverURL: URL
    var webURL: URL?
    var galleryID: String
    var bookingID: String
    var destinationLabel: String
    var createdAt: Date
    var jpegQuality: Double
    var longEdgePixels: Int?
    var protectedOriginalPaths: [String]
    var stagingFolderPath: String
    var remoteTransferID: String?
    var status: TransferStatus
    var pausedReason: String?
    var items: [TransferItemRecord]

    var counts: TransferCounts {
        var counts = TransferCounts()
        for item in items {
            switch item.phase {
            case .queued: counts.queued += 1
            case .rendered: counts.rendered += 1
            case .processing: counts.processing += 1
            case .ready: counts.ready += 1
            case .failed: counts.failed += 1
            }
        }
        return counts
    }

    var fractionComplete: Double {
        items.isEmpty ? 0 : Double(counts.ready) / Double(items.count)
    }

    /// True when "Retry failed" can do something: a failed photo the server manifest already
    /// lists and whose staged JPEG is still tracked. Photos that failed to render cannot rejoin.
    var hasRetryableFailures: Bool {
        items.contains { $0.phase == .failed && $0.remoteItemID != nil && $0.stagedPath != nil }
    }

    /// Anything not yet ready or definitively failed still needs a run.
    var hasUnfinishedWork: Bool {
        items.contains { $0.phase != .ready && $0.phase != .failed }
    }
}
