import AppKit
import Foundation
import UniformTypeIdentifiers

/// LUT import, choosing, and keeping a project's LUTs available.
extension EditorStore {
    /// Imports one `.cube` file off the main actor. The file is only read; a copy goes in the library.
    @discardableResult
    func importLUT(from url: URL) async -> LUTReference? {
        let library = lutLibrary
        do {
            let reference = try await Task.detached(priority: .userInitiated) { try library.importLUT(from: url) }.value
            availableLUTs = library.references()
            missingLUTs.removeAll { $0.contentHash == reference.contentHash }
            statusMessage = "Imported LUT \(reference.displayName)"
            return reference
        } catch {
            lastError = "\(url.lastPathComponent) could not be imported: \(error.localizedDescription)"
            return nil
        }
    }

    /// Asks for a `.cube` file and imports it.
    func chooseAndImportLUT() async -> LUTReference? {
        let panel = NSOpenPanel()
        panel.title = "Import LUT"
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return await importLUT(from: url)
    }

    // MARK: Choosing

    /// Source color for media items; `.automatic` clears the choice.
    func setColorInput(_ transform: ColorInputTransform, forAssets assetIDs: Set<UUID>) {
        for id in assetIDs {
            if transform == .automatic { project.colorInputByAssetID.removeValue(forKey: id) } else { project.colorInputByAssetID[id] = transform }
        }
        loadReferencedLUTs()
        refreshVideoAfterColorChange()
    }

    /// The selected photo's creative LUT; nil removes it.
    func setPhotoLUT(_ reference: LUTReference?) {
        updateAdjustments { adjustments in
            adjustments.lut = reference.map { LUTApplication(reference: $0, intensity: adjustments.lut?.intensity ?? 1) }
        }
        loadReferencedLUTs()
    }

    /// The selected timeline clip's creative LUT; nil removes it.
    func setClipLUT(_ reference: LUTReference?) {
        updateSelectedVideoAdjustments { adjustments in
            adjustments.lut = reference.map { LUTApplication(reference: $0, intensity: adjustments.lut?.intensity ?? 1) }
        }
        loadReferencedLUTs()
    }

    // MARK: Availability

    /// Loads every LUT the project references, from the project's own `LUTs` folder or the library,
    /// off the main actor. Missing ones are listed; renders go on without them.
    func loadReferencedLUTs() {
        let references = project.referencedLUTs
        let unloaded = references.filter { LoadedLUTs.shared.lut($0.contentHash) == nil }
        guard !unloaded.isEmpty else {
            missingLUTs = []
            return
        }
        let library = lutLibrary
        let folder = projectURL?.deletingLastPathComponent()
        let projectID = project.id
        Task {
            let missing = await Task.detached(priority: .userInitiated) {
                unloaded.filter { library.load($0, projectFolder: folder) == nil }
            }.value
            guard project.id == projectID else { return }
            missingLUTs = missing.sorted { $0.displayName < $1.displayName }
            if let first = missingLUTs.first {
                statusMessage = missingLUTs.count == 1
                    ? "LUT “\(first.displayName)” is missing, so it is not applied"
                    : "\(missingLUTs.count) LUTs are missing, so they are not applied"
            }
            if missing.count < unloaded.count {
                refreshPreview()
                refreshVideoAfterColorChange()
            }
        }
    }

    /// Source-color LUTs for the timeline: loaded ones, and a warning for each missing one.
    func resolvedInputLUTs() -> (resolved: [UUID: ResolvedLUT], warnings: [String]) {
        var resolved: [UUID: ResolvedLUT] = [:]
        var warnings: [String] = []
        for (assetID, input) in project.colorInputByAssetID {
            guard case .lut(let reference) = input else { continue }
            if let lut = LoadedLUTs.shared.lut(reference.contentHash) {
                resolved[assetID] = ResolvedLUT(hash: reference.contentHash, lut: lut)
            } else {
                let name = project.media.first { $0.id == assetID }?.filename ?? "a clip"
                warnings.append("Source color LUT “\(reference.displayName)” for \(name) is missing; showing it without the LUT.")
            }
        }
        return (resolved, warnings.sorted())
    }

    /// Media shown through OpenColorIO: chosen as ACES, or left on Automatic and detected as V-Log.
    /// (ACES chosen by hand covers V-Log whose camera metadata was lost.) Apple Log has no OCIO
    /// transform yet (plan Task 13.3), so it is never sent through the V-Log one.
    func resolvedOCIOInputs() -> [UUID: OCIOInputTransform] {
        project.media.reduce(into: [:]) { result, asset in
            let transfer = asset.sourceColor?.transfer
            switch project.colorInput(for: asset.id) {
            case .aces where transfer != .appleLog: result[asset.id] = .vLogVGamut
            case .automatic where transfer == .vLog: result[asset.id] = .vLogVGamut
            default: break
            }
        }
    }

    /// Copies the project's LUTs into a `LUTs` folder next to the saved project. Best effort: a
    /// failure leaves the project saved and says so.
    func copyReferencedLUTs(nextTo projectFile: URL) {
        let references = project.referencedLUTs
        guard !references.isEmpty else { return }
        do {
            try lutLibrary.copy(references, intoProjectFolder: projectFile.deletingLastPathComponent())
        } catch {
            statusMessage = "Saved, but the LUTs could not be copied next to the project: \(error.localizedDescription)"
        }
    }

    private func refreshVideoAfterColorChange() {
        if isTimelinePlayback {
            rebuildTimelineForColorChange()
        } else if let asset = selectedVideoAsset {
            selectVideo(asset)
        }
    }
}
