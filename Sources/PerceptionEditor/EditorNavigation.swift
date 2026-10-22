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
                RailStep(id: "video.audio", title: "Audio", symbol: "waveform", workspace: .videoAudio),
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
    /// 1…9 in order; nil from the tenth step on (one digit only), so a long list never traps.
    let key: Character?

    /// Agents sits outside the numbered steps so new steps never collide with it.
    static let agentsKey: Character = "0"

    /// Steps of both categories in order, Command-1 onward.
    static let all: [EditorStepShortcut] = make(from: EditorCategory.allCases.flatMap(\.steps))

    static func make(from steps: [RailStep]) -> [EditorStepShortcut] {
        steps.enumerated().map { index, step in
            EditorStepShortcut(step: step, key: index < 9 ? Character(String(index + 1)) : nil)
        }
    }
}

extension Workspace {
    /// True for every screen of the Video category's editing flow (Cut, Color, Audio, Export).
    var isVideo: Bool {
        switch self {
        case .video, .videoColor, .videoAudio, .videoExport: true
        default: false
        }
    }

    /// The category a screen belongs to; nil for screens shared by both (Library) or outside both (Agents).
    var category: EditorCategory? {
        switch self {
        case .cull, .photo, .export: .photo
        case .video, .videoColor, .videoAudio, .videoExport: .video
        case .library, .agents: nil
        }
    }
}
