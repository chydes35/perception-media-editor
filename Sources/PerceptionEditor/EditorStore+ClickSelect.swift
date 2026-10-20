import AppKit

extension EditorStore {
    /// Click anything in the photo to select it. Clicks add to the selection, ⌥-clicks carve parts out.
    func startClickSelection() {
        guard let asset = selectedAsset, asset.kind == .photo, !isEditingCrop, !isClickSelecting else { return }
        cancelAutoAdjustment()
        cancelSkySelection()
        cancelSubjectSelection()
        cancelWhiteBalancePicking()
        endRetouchEditing()
        endMaskEditing()
        exitZoom100()
        previewMode = .edited
        isClickSelecting = true
        isPreparingClickSelection = true
        clickPoints = []
        clickMasks = []
        clickGranularity = 1
        subjectSelectionOverlay = nil
        statusMessage = "Getting the photo ready for selection…"
        let requestID = UUID()
        clickRequestID = requestID
        let service = clickSelectionService
        Task { [weak self] in
            do {
                try await service.prepare(url: asset.url, photoID: asset.id)
                guard let self, clickRequestID == requestID, isClickSelecting else { return }
                isPreparingClickSelection = false
                statusMessage = "Click what you want to select. ⌥-click removes a part."
            } catch {
                guard let self, clickRequestID == requestID else { return }
                cancelClickSelection()
                lastError = error.localizedDescription
                statusMessage = "Click selection could not be started"
            }
        }
    }

    func cancelClickSelection() {
        clickRequestID = UUID()
        clickOverlayTask?.cancel()
        clickOverlayTask = nil
        isClickSelecting = false
        isPreparingClickSelection = false
        isDecodingClickSelection = false
        clickPoints = []
        clickMasks = []
        subjectSelectionOverlay = nil
    }

    /// `point` is in the finished photo's top-left normalized coordinates, as for the subject picker.
    func clickSelect(at point: NormalizedPoint, include: Bool) {
        guard isClickSelecting, !isPreparingClickSelection, let geometry = currentGeometry else { return }
        let source = geometry.source(fromFinished: point)
        clickPoints.append(SegmentationPoint(x: source.x, y: source.y, include: include))
        decodeClickSelection()
    }

    func undoClickPoint() {
        guard isClickSelecting, !clickPoints.isEmpty else { return }
        clickPoints.removeLast()
        if clickPoints.isEmpty {
            clickRequestID = UUID()
            clickMasks = []
            subjectSelectionOverlay = nil
            isDecodingClickSelection = false
        } else {
            decodeClickSelection()
        }
    }

    func setClickGranularity(_ index: Int) {
        guard !clickMasks.isEmpty else { return }
        clickGranularity = min(max(index, 0), clickMasks.count - 1)
        showClickOverlay()
    }

    func acceptClickSelection() {
        guard isClickSelecting, clickMasks.indices.contains(clickGranularity) else { return }
        let png = clickMasks[clickGranularity].png
        cancelClickSelection()
        nextHistoryLabel = "Click to Select"
        _ = addMask(.subject(SubjectMask(png: png)))
        showMaskOverlay = true
        refreshPreview()
        statusMessage = "Selected. Use Brush to refine its edge and the sliders to adjust it."
    }

    private func decodeClickSelection() {
        guard let asset = selectedAsset else { return }
        let requestID = UUID()
        clickRequestID = requestID
        isDecodingClickSelection = true
        let points = clickPoints
        let service = clickSelectionService
        Task { [weak self] in
            do {
                let masks = try await service.masks(photoID: asset.id, points: points)
                guard let self, clickRequestID == requestID, isClickSelecting, selectedAssetID == asset.id else { return }
                isDecodingClickSelection = false
                // The first click picks the model's most confident sensible mask; later clicks keep the size chosen.
                if clickMasks.isEmpty || points.count == 1 { clickGranularity = ClickMask.defaultIndex(in: masks) }
                clickMasks = masks
                clickGranularity = min(clickGranularity, masks.count - 1)
                showClickOverlay()
            } catch {
                guard let self, clickRequestID == requestID else { return }
                isDecodingClickSelection = false
                if !(error is CancellationError) {
                    lastError = error.localizedDescription
                    statusMessage = "Selection could not be completed"
                }
            }
        }
    }

    private func showClickOverlay() {
        guard clickMasks.indices.contains(clickGranularity), let asset = selectedAsset else { return }
        clickOverlayTask?.cancel()
        let png = clickMasks[clickGranularity].png
        let adjustments = selectedAdjustments
        let renderer = photoRenderer
        let requestID = clickRequestID
        clickOverlayTask = Task { [weak self] in
            let overlay = await renderer.subjectSelectionOverlay(url: asset.url, png: png, adjustments: adjustments)
            guard let self, !Task.isCancelled, clickRequestID == requestID, isClickSelecting,
                  selectedAssetID == asset.id, let overlay else { return }
            subjectSelectionOverlay = NSImage(
                cgImage: overlay.cgImage, size: NSSize(width: overlay.cgImage.width, height: overlay.cgImage.height))
        }
    }
}
