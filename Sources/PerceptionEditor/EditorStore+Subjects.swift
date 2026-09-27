import AppKit

extension EditorStore {
    /// Analyze once, then let the user choose a single detected foreground instance or all.
    func startSubjectSelection() {
        guard selectedAsset?.kind == .photo, !isEditingCrop, !isAnalyzingSubjects else { return }
        cancelWhiteBalancePicking()
        endRetouchEditing()
        endMaskEditing()
        exitZoom100()
        previewMode = .edited
        if subjectAnalysis != nil {
            isPickingSubject = true
            statusMessage = "Click a subject in the photo, or choose one from the list"
            return
        }
        guard let asset = selectedAsset else { return }
        isAnalyzingSubjects = true
        statusMessage = "Analyzing subjects…"
        let requestID = UUID()
        subjectRequestID = requestID
        let analyzer = subjectAnalyzer
        let renderer = photoRenderer
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
                    let overlay = await renderer.subjectSelectionOverlay(
                        url: asset.url, png: analysis.allSubjectsPNG,
                        adjustments: selectedAdjustments
                    )
                    guard subjectRequestID == requestID,
                          selectedAssetID == asset.id else { return }
                    subjectSelectionOverlay = overlay.map {
                        NSImage(cgImage: $0.cgImage,
                                size: NSSize(width: $0.cgImage.width, height: $0.cgImage.height))
                    }
                    isAnalyzingSubjects = false
                    isPickingSubject = true
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
        subjectRequestID = UUID()
        isAnalyzingSubjects = false
        isPickingSubject = false
        subjectAnalysis = nil
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
        isPickingSubject = false
        subjectSelectionOverlay = nil
        nextHistoryLabel = "Select Subject"
        _ = addMask(.subject(SubjectMask(png: png)))
        showMaskOverlay = true
        refreshPreview()
        statusMessage = "Subject selected. Use Brush to refine its edge and the sliders to adjust it."
    }
}
