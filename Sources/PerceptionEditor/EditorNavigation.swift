import Foundation
import CoreGraphics

enum EditorMetrics {
    static let railButtonHeight: CGFloat = 56
    static let categoryButtonHeight: CGFloat = 36
    static let railWidth: CGFloat = 96
}

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
                RailStep(id: "video.color", title: "Color", symbol: "camera.filters", workspace: .videoColor),
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

/// Keyboard shortcut for one Workspace-menu entry: Command plus a digit.
struct EditorStepShortcut {
    let step: RailStep
    let key: Character

    /// Agents sits outside the numbered steps so new steps never collide with it.
    static let agentsKey: Character = "0"

    /// Steps of both categories in order, Command-1 onward.
    static let all: [EditorStepShortcut] = EditorCategory.allCases
        .flatMap(\.steps)
        .enumerated()
        .map { EditorStepShortcut(step: $0.element, key: Character(String($0.offset + 1))) }
}

extension Workspace {
    /// True for every screen of the Video category's editing flow (Cut, Color, Export, later Audio).
    var isVideo: Bool {
        switch self {
        case .video, .videoColor, .videoExport: true
        default: false
        }
    }

    /// The category a screen belongs to; nil for screens shared by both (Library) or outside both (Agents).
    var category: EditorCategory? {
        switch self {
        case .cull, .photo, .export: .photo
        case .video, .videoColor, .videoExport: .video
        case .library, .agents: nil
        }
    }
}
