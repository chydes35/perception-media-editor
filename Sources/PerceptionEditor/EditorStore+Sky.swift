import Foundation

extension EditorStore {
    func startSkySelection() {
        guard let asset = selectedAsset, asset.kind == .photo, !isEditingCrop, !isAnalyzingSky else { return }
        cancelAutoAdjustment()
        cancelSubjectSelection()
        cancelWhiteBalancePicking()
        endRetouchEditing()
        endMaskEditing()
        exitZoom100()
        previewMode = .edited
        isAnalyzingSky = true
        statusMessage = "Detecting sky…"
        let requestID = UUID()
        skyRequestID = requestID
        let analyzer = skyAnalyzer
        Task { [weak self] in
            do {
                let png = try await analyzer.analyze(url: asset.url)
                self?.finishSkySelection(png: png, assetID: asset.id, requestID: requestID)
            } catch {
                guard let self, skyRequestID == requestID, selectedAssetID == asset.id else { return }
                isAnalyzingSky = false
                lastError = error.localizedDescription
                statusMessage = "Sky selection could not be completed"
            }
        }
    }

    func cancelSkySelection() {
        skyRequestID = UUID()
        isAnalyzingSky = false
    }

    /// Only the current request can create an edit. Navigating, changing tools, or canceling
    /// invalidates it, even though a Core ML inference already in progress may finish later.
    func finishSkySelection(png: Data, assetID: UUID, requestID: UUID) {
        guard isAnalyzingSky, skyRequestID == requestID, selectedAssetID == assetID, workspace == .photo else { return }
        isAnalyzingSky = false
        nextHistoryLabel = "Select Sky"
        _ = addMask(.sky(SubjectMask(png: png)))
        showMaskOverlay = true
        refreshPreview()
        statusMessage = "Sky selected. Refine its edge or use Add to sky and Remove spill."
    }
}
