import Foundation

enum AgentKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case photoCulling = "Photo Culling"
    case lookMatching = "Look Matching"
    case batchEditing = "Batch Editing"
    case photoQuality = "Photo Quality Control"
    case videoContinuity = "Video Continuity"
    case delivery = "Delivery Planning"
    case metadata = "Metadata & Organization"
    case relink = "Relink & Recovery"
    case projectHealth = "Project Health"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .photoCulling: "checkmark.circle"
        case .lookMatching: "wand.and.stars"
        case .batchEditing: "square.stack.3d.up"
        case .photoQuality: "eye.trianglebadge.exclamationmark"
        case .videoContinuity: "film.stack"
        case .delivery: "shippingbox"
        case .metadata: "tag"
        case .relink: "link.badge.plus"
        case .projectHealth: "stethoscope"
        }
    }

    var description: String {
        switch self {
        case .photoCulling:
            "Finds missing files, duplicate names, and assets that need a human quality decision."
        case .lookMatching:
            "Proposes copying the selected photo's look to comparable photos in the project."
        case .batchEditing:
            "Prepares a reversible batch adjustment pass from the selected photo."
        case .photoQuality:
            "Checks photo readiness, resolution, file availability, and export risk."
        case .videoContinuity:
            "Checks video assets and timeline clips for continuity and playback risks."
        case .delivery:
            "Builds a delivery checklist for the current photo set without writing exports."
        case .metadata:
            "Finds metadata gaps and proposes organization work that needs review."
        case .relink:
            "Reports missing originals and prepares safe relink candidates."
        case .projectHealth:
            "Reviews the project structure against a photography and videography workflow."
        }
    }
}

enum AgentSeverity: String, Codable, CaseIterable, Sendable {
    case critical = "Critical"
    case high = "High"
    case medium = "Medium"
    case low = "Low"
    case info = "Info"

    var sortOrder: Int {
        switch self {
        case .critical: 0
        case .high: 1
        case .medium: 2
        case .low: 3
        case .info: 4
        }
    }
}

struct AgentFinding: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let severity: AgentSeverity
    let title: String
    let detail: String
    let recommendation: String?
    let assetID: UUID?
    let clipID: UUID?

    init(
        id: UUID = UUID(),
        severity: AgentSeverity,
        title: String,
        detail: String,
        recommendation: String? = nil,
        assetID: UUID? = nil,
        clipID: UUID? = nil
    ) {
        self.id = id
        self.severity = severity
        self.title = title
        self.detail = detail
        self.recommendation = recommendation
        self.assetID = assetID
        self.clipID = clipID
    }
}

enum AgentChangeKind: String, Codable, Sendable {
    case copyPhotoAdjustments
}

struct AgentChange: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let kind: AgentChangeKind
    let sourceAssetID: UUID?
    let targetAssetID: UUID?
    let detail: String

    init(
        id: UUID = UUID(),
        kind: AgentChangeKind,
        sourceAssetID: UUID? = nil,
        targetAssetID: UUID? = nil,
        detail: String
    ) {
        self.id = id
        self.kind = kind
        self.sourceAssetID = sourceAssetID
        self.targetAssetID = targetAssetID
        self.detail = detail
    }
}

struct AgentReport: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let kind: AgentKind
    let startedAt: Date
    let finishedAt: Date
    let summary: String
    let findings: [AgentFinding]
    let proposedChanges: [AgentChange]
    let limitation: String?

    var highestSeverity: AgentSeverity {
        findings.map(\.severity).min { $0.sortOrder < $1.sortOrder } ?? .info
    }

    var hasChanges: Bool { !proposedChanges.isEmpty }

    init(
        id: UUID = UUID(),
        kind: AgentKind,
        startedAt: Date,
        finishedAt: Date = .now,
        summary: String,
        findings: [AgentFinding],
        proposedChanges: [AgentChange] = [],
        limitation: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.summary = summary
        self.findings = findings
        self.proposedChanges = proposedChanges
        self.limitation = limitation
    }
}
