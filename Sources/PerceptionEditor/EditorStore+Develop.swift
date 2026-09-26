import AppKit

extension EditorStore {
    // MARK: - RAW info

    /// Loads the selected RAW photo's as-shot white balance and engine defaults for the sliders.
    func refreshRawInfo(for asset: MediaAsset) {
        guard rawInfoAssetID != asset.id else { return }
        rawInfoAssetID = asset.id
        rawInfo = nil

        let url = asset.url
        let assetID = asset.id
        let renderer = photoRenderer
        Task { [weak self] in
            let info = await renderer.rawInfo(url: url)
            guard let self, rawInfoAssetID == assetID else { return }
            rawInfo = info
        }
    }

    var selectedIsRAW: Bool { rawInfo != nil }

    // MARK: - White balance

    /// The white balance the sliders show: the photo's own setting, or the as-shot value.
    var displayedTemperature: Double {
        selectedAdjustments.raw.temperature ?? rawInfo?.asShotTemperature ?? 5500
    }

    var displayedTint: Double {
        selectedAdjustments.raw.tint ?? rawInfo?.asShotTint ?? 0
    }

    func applyWhiteBalance(_ preset: WhiteBalancePreset) {
        updateAdjustments {
            $0.raw.temperature = preset.temperature
            $0.raw.tint = preset.tint
        }
        statusMessage = "White balance: \(preset.rawValue)"
    }

    func resetWhiteBalance() {
        updateAdjustments {
            $0.raw.temperature = nil
            $0.raw.tint = nil
        }
        statusMessage = "White balance: As Shot"
    }

    // MARK: - 100% view

    func toggleZoom100(at center: CGPoint? = nil) {
        if isZoom100 {
            exitZoom100()
        } else {
            enterZoom100(at: center ?? CGPoint(x: 0.5, y: 0.5))
        }
    }

    /// Shows the photo at one image pixel per screen pixel, centered on `center`
    /// (0–1 from the top-left of the finished photo). It uses the full RAW decode, so the first
    /// view of a photo takes about a second.
    func enterZoom100(at center: CGPoint = CGPoint(x: 0.5, y: 0.5)) {
        guard selectedAsset?.kind == .photo, compareAssetID == nil, !isEditingCrop else { return }
        zoomCenter = CGPoint(x: min(1, max(0, center.x)), y: min(1, max(0, center.y)))
        isZoom100 = true
        refreshFocus()
    }

    func exitZoom100() {
        guard isZoom100 else { return }
        isZoom100 = false
        focusImage = nil
        isLoadingFocus = false
        needsAnotherFocus = false
        focusTask?.cancel()
        focusTask = nil
        let renderer = focusRenderer
        Task { await renderer.releaseFullResolution() }
    }

    /// The view reports how many screen pixels it has, which is how much of the photo to render.
    func setFocusViewport(pixels: CGSize) {
        guard pixels.width >= 1, pixels.height >= 1, pixels != focusViewportPixels else { return }
        focusViewportPixels = pixels
        refreshFocus()
    }

    /// Pans the 100% view. `translation` is how far the photo was dragged, in screen pixels.
    func panZoom(from start: CGPoint, translation: CGSize) {
        guard focusFullSize.width > 0, focusFullSize.height > 0 else { return }
        zoomCenter = CGPoint(
            x: min(1, max(0, start.x - translation.width / focusFullSize.width)),
            y: min(1, max(0, start.y - translation.height / focusFullSize.height))
        )
        refreshFocus()
    }

    /// Renders the 100% view. Requests made while a render is running collapse into one
    /// follow-up render at the latest position, so dragging never queues stale work.
    func refreshFocus() {
        guard isZoom100, let asset = selectedAsset, asset.kind == .photo,
              focusViewportPixels.width >= 1, focusViewportPixels.height >= 1
        else { return }

        guard focusTask == nil else {
            needsAnotherFocus = true
            return
        }

        let assetID = asset.id
        let url = asset.url
        let adjustments = selectedAdjustments
        let center = zoomCenter
        let viewport = focusViewportPixels
        let renderer = focusRenderer
        isLoadingFocus = true

        focusTask = Task { [weak self] in
            let result = await renderer.focusRegion(
                url: url,
                adjustments: adjustments,
                center: center,
                viewportPixels: viewport
            )
            self?.finishFocus(assetID: assetID, result: result)
        }
    }

    private func finishFocus(assetID: UUID, result: FocusRender?) {
        focusTask = nil
        isLoadingFocus = false

        if isZoom100, selectedAssetID == assetID {
            if let result {
                focusImage = result.image.cgImage
                focusFullSize = result.fullSize
                // Keep the stored center honest when the region was pushed back inside the photo.
                zoomCenter = CGPoint(
                    x: result.region.midX / max(1, result.fullSize.width),
                    y: result.region.midY / max(1, result.fullSize.height)
                )
            } else {
                focusImage = nil
                statusMessage = "This photo could not be shown at 100%."
            }
        }

        if needsAnotherFocus {
            needsAnotherFocus = false
            refreshFocus()
        }
    }
}
