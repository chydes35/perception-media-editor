import Foundation

extension EditorStore {
    func startAutoAdjustment() {
        guard let asset = selectedAsset, asset.kind == .photo, workspace == .photo,
              !isEditingCrop, !isAnalyzingAuto else { return }
        endAdjustmentEdit()
        cancelWhiteBalancePicking()
        cancelSubjectSelection()
        endMaskEditing()
        endRetouchEditing()
        let current = selectedAdjustments
        let projectID = project.id
        let requestID = UUID()
        autoRequestID = requestID
        isAnalyzingAuto = true
        statusMessage = "Finding suggested basic adjustments…"
        let analyzer = autoAnalyzer
        Task { [weak self] in
            do {
                let suggestion = try await analyzer.analyze(url: asset.url, current: current)
                self?.finishAutoAdjustment(suggestion, assetID: asset.id, sourceURL: asset.url, projectID: projectID,
                                           requestID: requestID, original: current)
            } catch {
                guard let self, autoRequestID == requestID, isAnalyzingAuto else { return }
                isAnalyzingAuto = false
                lastError = error.localizedDescription
                statusMessage = "Auto adjustment could not be completed"
            }
        }
    }

    func cancelAutoAdjustment() {
        autoRequestID = UUID()
        isAnalyzingAuto = false
    }

    func finishAutoAdjustment(_ suggestion: AutoAdjustmentSuggestion, assetID: UUID, sourceURL: URL,
                              projectID: UUID, requestID: UUID, original: PhotoAdjustments) {
        guard isAnalyzingAuto, autoRequestID == requestID else { return }
        isAnalyzingAuto = false
        guard selectedAssetID == assetID, selectedAsset?.url == sourceURL,
              project.id == projectID, workspace == .photo,
              !isEditingCrop, selectedAdjustments == original else { return }
        nextHistoryLabel = "Auto"
        updateAdjustments { $0 = suggestion.applying(to: $0) }
        previewMode = .edited
        statusMessage = "Auto applied. Fine-tune the basic sliders to taste."
    }
}
