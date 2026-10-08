import Foundation

extension EditorStore {
    var canAutoAdjustPhoto: Bool {
        guard let asset = selectedAsset, asset.kind == .photo else { return false }
        return workspace == .photo && !isMissing(asset) && !isAnalyzingAuto
            && !isEditingCrop && activeAdjustmentSnapshot == nil
    }

    @discardableResult
    func startAutoAdjustment() -> Task<Void, Never>? {
        guard canAutoAdjustPhoto, let asset = selectedAsset else { return nil }
        cancelWhiteBalancePicking()
        cancelSubjectSelection()
        endMaskEditing()
        endRetouchEditing()
        let current = selectedAdjustments
        let projectID = project.id
        let generation = projectGeneration
        let requestID = UUID()
        autoRequestID = requestID
        isAnalyzingAuto = true
        statusMessage = "Finding suggested basic adjustments…"
        let analyzer = autoAnalyzer
        let analyze = autoAdjustmentAnalyzer
        let task = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let suggestion: AutoAdjustmentSuggestion
                if let analyze { suggestion = try await analyze(asset.url, current) }
                else { suggestion = try await analyzer.analyze(url: asset.url, current: current) }
                try Task.checkCancellation()
                self?.finishAutoAdjustment(suggestion, assetID: asset.id, sourceURL: asset.url,
                                           projectID: projectID, generation: generation,
                                           requestID: requestID, original: current)
            } catch {
                guard let self, autoRequestID == requestID, projectGeneration == generation else { return }
                isAnalyzingAuto = false
                autoAdjustmentTask = nil
                if error is CancellationError { return }
                lastError = error.localizedDescription
                statusMessage = "Auto adjustment could not be completed"
            }
        }
        autoAdjustmentTask = task
        return task
    }

    func cancelAutoAdjustment() {
        autoAdjustmentTask?.cancel()
        autoAdjustmentTask = nil
        autoRequestID = UUID()
        isAnalyzingAuto = false
    }

    func finishAutoAdjustment(_ suggestion: AutoAdjustmentSuggestion, assetID: UUID, sourceURL: URL,
                              projectID: UUID, generation: UUID, requestID: UUID, original: PhotoAdjustments) {
        guard isAnalyzingAuto, autoRequestID == requestID else { return }
        isAnalyzingAuto = false
        autoAdjustmentTask = nil
        guard projectGeneration == generation, selectedAssetID == assetID, selectedAsset?.url == sourceURL,
              project.id == projectID, workspace == .photo,
              !isEditingCrop, activeAdjustmentSnapshot == nil, selectedAdjustments == original else { return }
        let changed = applyToPhotos([assetID], label: "Auto") { suggestion.applying(to: $0) }
        previewMode = .edited
        if isZoom100 { refreshFocus() }
        statusMessage = changed > 0 ? "Auto applied. Fine-tune the basic sliders to taste." : "Auto: no further changes needed"
    }
}
