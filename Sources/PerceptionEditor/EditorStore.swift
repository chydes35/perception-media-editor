import AppKit
import Combine
import CoreImage
import UniformTypeIdentifiers

@MainActor
final class EditorStore: ObservableObject {
    @Published var project = EditorProject.starter
    @Published var workspace: Workspace = .library
    @Published var selectedAssetID: UUID?
    @Published var renderedPreview: NSImage?
    @Published var isShowingOriginal = false
    @Published var statusMessage = "Ready"
    @Published var lastError: String?

    private(set) var sourceImages: [UUID: CIImage] = [:]
    private(set) var projectURL: URL?

    let presets = PhotoPreset.builtIns
    private let renderer = PhotoRenderer.shared
    private let document = ProjectDocument()

    var selectedAsset: MediaAsset? {
        guard let selectedAssetID else { return nil }
        return project.media.first(where: { $0.id == selectedAssetID })
    }

    var selectedAdjustments: PhotoAdjustments {
        get {
            guard let selectedAssetID else { return .neutral }
            return project.adjustmentsByAssetID[selectedAssetID] ?? .neutral
        }
        set {
            guard let selectedAssetID else { return }
            project.adjustmentsByAssetID[selectedAssetID] = newValue
            refreshPreview()
        }
    }

    func importMedia() {
        let panel = NSOpenPanel()
        panel.title = "Import Photos"
        panel.prompt = "Import"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .rawImage]

        guard panel.runModal() == .OK else { return }
        importURLs(panel.urls)
    }

    func importURLs(_ urls: [URL]) {
        var importedCount = 0

        for url in urls {
            guard let image = renderer.loadImage(from: url) else { continue }
            let asset = MediaAsset(url: url)
            project.media.append(asset)
            project.adjustmentsByAssetID[asset.id] = .neutral
            sourceImages[asset.id] = image
            selectedAssetID = asset.id
            importedCount += 1
        }

        if importedCount > 0 {
            workspace = .photo
            statusMessage = "Imported \(importedCount) photo\(importedCount == 1 ? "" : "s")"
            refreshPreview()
        } else {
            lastError = "No supported photos were imported."
        }
    }

    func select(_ asset: MediaAsset) {
        selectedAssetID = asset.id
        loadSourceIfNeeded(for: asset)
        refreshPreview()
    }

    func updateAdjustments(_ update: (inout PhotoAdjustments) -> Void) {
        guard selectedAssetID != nil else { return }
        var adjustments = selectedAdjustments
        update(&adjustments)
        selectedAdjustments = adjustments
    }

    func apply(_ preset: PhotoPreset) {
        selectedAdjustments = preset.adjustments
        statusMessage = "Applied \(preset.name)"
    }

    func resetAdjustments() {
        selectedAdjustments = .neutral
        statusMessage = "Adjustments reset"
    }

    func rotate(clockwise: Bool) {
        updateAdjustments { adjustments in
            let delta = clockwise ? 1 : -1
            adjustments.rotationQuarterTurns = (adjustments.rotationQuarterTurns + delta) % 4
        }
    }

    func refreshPreview() {
        guard let selectedAssetID else {
            renderedPreview = nil
            return
        }

        if sourceImages[selectedAssetID] == nil, let asset = selectedAsset {
            loadSourceIfNeeded(for: asset)
        }

        guard let source = sourceImages[selectedAssetID] else {
            renderedPreview = nil
            return
        }

        let adjustments = isShowingOriginal ? PhotoAdjustments.neutral : selectedAdjustments
        renderedPreview = renderer.preview(source, adjustments: adjustments)
    }

    func setShowingOriginal(_ showing: Bool) {
        isShowingOriginal = showing
        refreshPreview()
    }

    func newProject() {
        project = EditorProject.starter
        projectURL = nil
        selectedAssetID = nil
        sourceImages = [:]
        renderedPreview = nil
        workspace = .library
        statusMessage = "New project"
    }

    func saveProject(saveAs: Bool = false) {
        let destination: URL?

        if !saveAs, let projectURL {
            destination = projectURL
        } else {
            let panel = NSSavePanel()
            panel.title = "Save Perception Media Project"
            panel.nameFieldStringValue = "\(project.name).\(ProjectDocument.fileExtension)"
            panel.allowedContentTypes = [UTType(filenameExtension: ProjectDocument.fileExtension) ?? .json]
            destination = panel.runModal() == .OK ? panel.url : nil
        }

        guard let destination else { return }

        do {
            try document.save(project, to: destination)
            projectURL = destination
            statusMessage = "Saved \(destination.lastPathComponent)"
        } catch {
            lastError = error.localizedDescription
        }
    }

    func openProject() {
        let panel = NSOpenPanel()
        panel.title = "Open Perception Media Project"
        panel.allowedContentTypes = [UTType(filenameExtension: ProjectDocument.fileExtension) ?? .json]
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            project = try document.load(from: url)
            projectURL = url
            selectedAssetID = project.media.first?.id
            sourceImages = [:]
            if let first = project.media.first {
                loadSourceIfNeeded(for: first)
            }
            refreshPreview()
            statusMessage = "Opened \(url.lastPathComponent)"
        } catch {
            lastError = error.localizedDescription
        }
    }

    func exportSelectedPhoto() {
        guard
            let selectedAssetID,
            let asset = selectedAsset
        else {
            lastError = "Select a photo before exporting."
            return
        }

        loadSourceIfNeeded(for: asset)
        guard let source = sourceImages[selectedAssetID] else {
            lastError = "The original file could not be loaded. Relink support is planned for V0.2."
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export Edited Photo"
        panel.allowedContentTypes = [.jpeg, .png]
        panel.nameFieldStringValue = asset.url.deletingPathExtension().lastPathComponent + "_edited.jpg"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let type: UTType = url.pathExtension.lowercased() == "png" ? .png : .jpeg
        do {
            try renderer.export(source, adjustments: selectedAdjustments, to: url, type: type)
            statusMessage = "Exported \(url.lastPathComponent)"
        } catch {
            lastError = error.localizedDescription
        }
    }

    func thumbnail(for asset: MediaAsset) -> NSImage? {
        loadSourceIfNeeded(for: asset)
        guard let source = sourceImages[asset.id] else { return nil }
        let adjustments = project.adjustmentsByAssetID[asset.id] ?? .neutral
        return renderer.preview(source, adjustments: adjustments, maxDimension: 420)
    }

    private func loadSourceIfNeeded(for asset: MediaAsset) {
        guard sourceImages[asset.id] == nil else { return }
        sourceImages[asset.id] = renderer.loadImage(from: asset.url)
    }
}
