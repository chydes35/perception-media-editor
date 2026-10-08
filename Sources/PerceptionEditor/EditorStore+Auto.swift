import Foundation

extension EditorStore {
    var canAutoAdjustPhoto: Bool {
        guard let asset = selectedAsset, asset.kind == .photo else { return false }
        return workspace != .video && workspace != .agents && !isMissing(asset)
            && !isAutoAdjusting && !isEditingCrop && activeAdjustmentSnapshot == nil
    }

    @discardableResult
    func autoAdjustPhoto() -> Task<Void, Never>? {
        guard canAutoAdjustPhoto, let asset = selectedAsset else { return nil }
        if workspace != .photo { workspace = .photo }
        let generation = projectGeneration
        let before = selectedAdjustments
        let operation = UUID()
        autoAdjustmentID = operation
        isAutoAdjusting = true
        statusMessage = "Analyzing \(asset.filename)…"
        let renderer = photoRenderer
        let analyzer = autoToneAnalyzer
        let task = Task { [weak self] in
            let result: AutoToneAdjustments?
            if let analyzer { result = await analyzer(asset.url, before) }
            else { result = await renderer.autoTone(url: asset.url, adjustments: before) }
            guard let self, autoAdjustmentID == operation else { return }
            isAutoAdjusting = false
            autoAdjustmentTask = nil
            autoAdjustmentID = nil
            guard !Task.isCancelled, projectGeneration == generation, selectedAssetID == asset.id,
                  project.media.contains(where: { $0.id == asset.id && $0.url == asset.url }) else { return }
            guard selectedAdjustments == before, activeAdjustmentSnapshot == nil, !isEditingCrop else {
                statusMessage = "Photo changed while Auto was analyzing. Run Auto again."
                return
            }
            guard let result else {
                lastError = "This photo could not be analyzed. Check that the original is available."
                statusMessage = "Auto adjustment failed"
                return
            }
            let changed = applyToPhotos([asset.id], label: "Auto Adjust") { result.applying(to: $0) }
            if previewMode == .original { previewMode = .edited }
            if isZoom100 { refreshFocus() }
            statusMessage = changed > 0 ? "Auto adjusted \(asset.filename)" : "Auto: no further changes needed"
        }
        autoAdjustmentTask = task
        return task
    }

    func cancelAutoAdjustment() {
        autoAdjustmentTask?.cancel()
        autoAdjustmentTask = nil
        autoAdjustmentID = nil
        isAutoAdjusting = false
    }
}
