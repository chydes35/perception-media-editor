import Foundation

enum EditorCategory: String, CaseIterable, Identifiable, Sendable {
    case photo = "Photo"
    case video = "Video"

    var id: String { rawValue }

    var steps: [RailStep] {
        switch self {
        case .photo:
            [
                RailStep(id: "photo.import", title: "Import", symbol: "square.and.arrow.down", workspace: .library),
                RailStep(id: "photo.cull", title: "Cull", symbol: "flag", workspace: .cull),
                RailStep(id: "photo.develop", title: "Develop", symbol: "slider.horizontal.3", workspace: .photo),
                RailStep(id: "photo.export", title: "Export", symbol: "square.and.arrow.up", workspace: .export),
            ]
        case .video:
            [
                RailStep(id: "video.import", title: "Import", symbol: "square.and.arrow.down", workspace: .library),
                RailStep(id: "video.cut", title: "Cut", symbol: "scissors", workspace: .video),
                RailStep(id: "video.export", title: "Export", symbol: "square.and.arrow.up", workspace: .videoExport),
            ]
        }
    }
}

struct RailStep: Identifiable, Equatable {
    let id: String
    let title: String
    let symbol: String
    let workspace: Workspace
}

extension Workspace {
    /// The category a screen belongs to; nil for screens shared by both (Library) or outside both (Agents).
    var category: EditorCategory? {
        switch self {
        case .cull, .photo, .export: .photo
        case .video, .videoExport: .video
        case .library, .agents: nil
        }
    }
}
