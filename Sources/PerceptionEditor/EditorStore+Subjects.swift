import AppKit

extension EditorStore {
    /// Analyze once, then let the user choose a single detected foreground instance or all.
    func startSubjectSelection() {
        guard selectedAsset?.kind == .photo, !isEditingCrop, !isAnalyzingSubjects else { return }
        cancelAutoAdjustment()
        cancelSkySelection()
        cancelWhiteBalancePicking()
        endRetouchEditing()
        endMaskEditing()
        exitZoom100()
        previewMode = .edited
        if subjectAnalysis != nil {
            isPickingSubject = true
            previewSubjectCandidate(nil)
            statusMessage = "Click a subject in the photo, or choose one from the list"
            return
        }
        guard let asset = selectedAsset else { return }
        isAnalyzingSubjects = true
        statusMessage = "Analyzing subjects…"
        let requestID = UUID()
        subjectRequestID = requestID
        let analyzer = subjectAnalyzer
        Task { [weak self] in
            do {
                let analysis = try await analyzer.analyze(url: asset.url)
                guard let self, subjectRequestID == requestID,
                      selectedAssetID == asset.id else { return }
                subjectAnalysis = analysis
                if analysis.candidates.count == 1 {
                    isAnalyzingSubjects = false
                    addSubjectMask(analysis.candidates[0].png)
                } else {
                    isAnalyzingSubjects = false
                    isPickingSubject = true
                    previewSubjectCandidate(nil)
                    statusMessage = "Found \(analysis.candidates.count) subjects. Click one or choose from the list."
                }
            } catch {
                guard let self, subjectRequestID == requestID else { return }
                isAnalyzingSubjects = false
                lastError = error.localizedDescription
            }
        }
    }

    func cancelSubjectSelection() {
        cancelSkySelection()
        subjectRequestID = UUID()
        isAnalyzingSubjects = false
        stopSubjectPreview()
        subjectAnalysis = nil
        subjectOverlayCache.removeAll()
        subjectOverlayAdjustments = nil
    }

    /// Preview one candidate without adding a mask or recording an edit. Rapid pointer
    /// movement is debounced, and request IDs prevent an older overlay from flashing back.
    func previewSubjectCandidate(_ id: Int?) {
        guard isPickingSubject, let analysis = subjectAnalysis, let asset = selectedAsset else { return }
        let candidate = id.flatMap { id in analysis.candidates.first { $0.id == id } }
        let nextID = candidate?.id
        let adjustments = selectedAdjustments
        let key = nextID ?? 0
        if highlightedSubjectID == nextID, subjectOverlayAdjustments == adjustments,
           subjectSelectionOverlay != nil || subjectOverlayTask != nil { return }
        subjectOverlayTask?.cancel()
        let requestID = UUID()
        subjectOverlayRequestID = requestID
        highlightedSubjectID = nextID
        if subjectOverlayAdjustments != adjustments {
            subjectOverlayCache.removeAll()
            subjectOverlayAdjustments = adjustments
        }
        if let index = subjectOverlayCache.firstIndex(where: { $0.id == key }) {
            let cached = subjectOverlayCache.remove(at: index)
            subjectOverlayCache.append(cached)
            subjectSelectionOverlay = cached.image
            subjectOverlayTask = nil
            return
        }
        subjectSelectionOverlay = nil
        let png = candidate?.png ?? analysis.allSubjectsPNG
        let renderer = photoRenderer
        subjectOverlayTask = Task { [weak self] in
            if nextID != nil {
                do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            let overlay = await renderer.subjectSelectionOverlay(
                url: asset.url, png: png, adjustments: adjustments
            )
            guard let self, !Task.isCancelled, subjectOverlayRequestID == requestID,
                  isPickingSubject, selectedAssetID == asset.id else { return }
            subjectOverlayTask = nil
            guard let overlay else { return }
            let image = NSImage(cgImage: overlay.cgImage,
                                size: NSSize(width: overlay.cgImage.width, height: overlay.cgImage.height))
            subjectOverlayCache.append((key, image))
            if subjectOverlayCache.count > 4 { subjectOverlayCache.removeFirst() }
            subjectSelectionOverlay = image
        }
    }

    /// Hover positions use the same crop/rotation mapping as clicks.
    func previewSubject(at point: NormalizedPoint?) {
        guard let point, let geometry = currentGeometry else {
            previewSubjectCandidate(nil)
            return
        }
        previewSubjectCandidate(subjectAnalysis?.candidate(at: geometry.source(fromFinished: point))?.id)
    }

    private func stopSubjectPreview() {
        subjectOverlayTask?.cancel()
        subjectOverlayTask = nil
        subjectOverlayRequestID = UUID()
        isPickingSubject = false
        highlightedSubjectID = nil
        subjectSelectionOverlay = nil
    }

    /// `point` is in the finished photo's top-left normalized coordinates.
    func pickSubject(at point: NormalizedPoint) {
        guard isPickingSubject, let analysis = subjectAnalysis,
              let geometry = currentGeometry else { return }
        let source = geometry.source(fromFinished: point)
        guard let candidate = analysis.candidate(at: source) else {
            lastError = "Click inside a detected subject, or choose one from the list."
            return
        }
        selectSubjectCandidate(candidate.id)
    }

    func selectSubjectCandidate(_ id: Int) {
        guard let candidate = subjectAnalysis?.candidates.first(where: { $0.id == id }) else { return }
        addSubjectMask(candidate.png)
    }

    func selectAllSubjects() {
        guard let png = subjectAnalysis?.allSubjectsPNG else { return }
        addSubjectMask(png)
    }

    private func addSubjectMask(_ png: Data) {
        stopSubjectPreview()
        nextHistoryLabel = "Select Subject"
        _ = addMask(.subject(SubjectMask(png: png)))
        showMaskOverlay = true
        refreshPreview()
        statusMessage = "Subject selected. Use Brush to refine its edge and the sliders to adjust it."
    }
}
