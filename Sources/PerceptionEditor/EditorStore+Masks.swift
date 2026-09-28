import AppKit

enum MaskTool: Equatable {
    case none
    case linear
    case radial
    case brush
}

extension EditorStore {
    // MARK: - Reading

    var masks: [LocalMask] { selectedAdjustments.masks }

    var selectedMask: LocalMask? {
        guard let selectedMaskID else { return nil }
        return masks.first { $0.id == selectedMaskID }
    }

    /// True while the photo is showing mask handles or waiting for a mask to be drawn.
    var isMaskEditing: Bool { maskTool != .none || selectedMask != nil }

    func displayName(for mask: LocalMask) -> String {
        if let name = mask.name, !name.isEmpty { return name }
        let sameKind = masks.filter { $0.shape.kindName == mask.shape.kindName }
        let number = (sameKind.firstIndex(where: { $0.id == mask.id }) ?? 0) + 1
        return "\(mask.shape.kindName) \(number)"
    }

    /// How the original photo maps to the finished picture, for placing and reading mask handles.
    var currentGeometry: ImageGeometry? {
        guard let asset = selectedAsset, let width = asset.pixelWidth, let height = asset.pixelHeight,
              width > 0, height > 0
        else { return nil }
        return ImageGeometry(sourceSize: CGSize(width: width, height: height), adjustments: selectedAdjustments)
    }

    // MARK: - Tools and selection

    func chooseMaskTool(_ tool: MaskTool) {
        guard selectedAsset?.kind == .photo else { return }
        let next: MaskTool = (maskTool == tool) ? .none : tool
        if next != .none {
            cancelWhiteBalancePicking()
            cancelSubjectSelection()
            endRetouchEditing()
            exitZoom100()
            cancelCropEditing()
            previewMode = .edited
        }
        maskTool = next

        switch next {
        case .linear, .radial:
            selectedMaskID = nil   // the next drag draws a new mask
        case .brush:
            // Painting continues on the selected brush; otherwise the first stroke starts a new one.
            if selectedMask?.shape.isGradient != false { selectedMaskID = nil }
        case .none:
            break
        }
        refreshPreview()
    }

    func selectMask(_ id: UUID?) {
        if id != nil { cancelSubjectSelection() }
        if id != nil { endRetouchEditing() }
        selectedMaskID = id
        if id != nil {
            // Picking a brush mask while the brush is active keeps painting on it; anything else ends the tool.
            let keepsBrush = maskTool == .brush && selectedMask?.shape.isGradient == false
            maskTool = keepsBrush ? .brush : .none
        }
        refreshPreview()
    }

    /// Leaves mask editing without changing any mask.
    func endMaskEditing() {
        maskTool = .none
        selectedMaskID = nil
        isMaskInteracting = false
        maskOverlay = nil
    }

    func toggleMaskOverlay() {
        showMaskOverlay.toggle()
        refreshPreview()
    }

    /// Escape: close the tool first, then the selected mask.
    @discardableResult
    func cancelMaskEditing() -> Bool {
        if maskTool != .none {
            maskTool = .none
        } else if selectedMaskID != nil {
            selectedMaskID = nil
        } else {
            return false
        }
        maskOverlay = nil
        refreshPreview()
        return true
    }

    func resizeBrush(by factor: Double) {
        brushSize = min(0.5, max(0.005, brushSize * factor))
    }

    /// Makes the add/remove correction mode explicit for a selected subject or sky mask.
    func beginSubjectRefinement(erasing: Bool) {
        guard selectedMask?.shape.rasterSelection != nil else { return }
        cancelSubjectSelection()
        cancelWhiteBalancePicking()
        endRetouchEditing()
        cancelCropEditing()
        exitZoom100()
        previewMode = .edited
        brushErasing = erasing
        maskTool = .brush
        showMaskOverlay = true
        refreshPreview()
        let kind = selectedMask?.shape.kindName.lowercased() ?? "selection"
        statusMessage = erasing
            ? "Paint over the unwanted area to remove it from the \(kind)"
            : "Paint over missing areas to add them to the \(kind)"
    }

    // MARK: - Changing masks

    /// Adds a mask and selects it. Callers that drag it afterwards wrap the drag in
    /// `beginAdjustmentEdit` and `endAdjustmentEdit`, so creating and shaping it is one undo step.
    @discardableResult
    func addMask(_ shape: MaskShape, adjustments: MaskAdjustments? = nil) -> UUID? {
        guard selectedAsset?.kind == .photo else { return nil }
        var mask = LocalMask(shape: shape)
        mask.adjustments = adjustments ?? Self.starterAdjustments
        let id = mask.id
        updateAdjustments { $0.masks.append(mask) }
        selectedMaskID = id
        return id
    }

    /// A new mask starts with a visible, modest change, so the first thing you see after drawing
    /// one is that it is doing something.
    static var starterAdjustments: MaskAdjustments {
        var adjustments = MaskAdjustments()
        adjustments.exposure = -0.5
        return adjustments
    }

    func updateMask(_ id: UUID, _ change: (inout LocalMask) -> Void) {
        updateAdjustments { adjustments in
            guard let index = adjustments.masks.firstIndex(where: { $0.id == id }) else { return }
            change(&adjustments.masks[index])
        }
    }

    func deleteMask(_ id: UUID) {
        nextHistoryLabel = "Delete mask"
        updateAdjustments { $0.masks.removeAll { $0.id == id } }
        if selectedMaskID == id { selectedMaskID = nil }
        maskOverlay = nil
    }

    func duplicateMask(_ id: UUID) {
        guard let original = masks.first(where: { $0.id == id }) else { return }
        var copy = original.duplicated()
        if let name = original.name { copy.name = name + " copy" }
        nextHistoryLabel = "Duplicate mask"
        updateAdjustments { $0.masks.append(copy) }
        selectedMaskID = copy.id
    }

    func resetMaskAdjustments(_ id: UUID) {
        nextHistoryLabel = "Reset mask"
        updateMask(id) { $0.adjustments = MaskAdjustments() }
    }

    // MARK: - Drawing gradients

    /// Starts a gradient where the pointer went down. `point` is in original-image coordinates.
    func beginGradient(_ tool: MaskTool, at point: NormalizedPoint) -> UUID? {
        beginAdjustmentEdit()
        isMaskInteracting = true
        let shape: MaskShape
        switch tool {
        case .linear:
            nextHistoryLabel = "Linear Gradient"
            shape = .linear(start: point, end: point)
        case .radial:
            nextHistoryLabel = "Radial Gradient"
            shape = .radial(center: point, radiusX: 0.02, radiusY: 0.02, rotation: 0, feather: 0.5)
        default:
            cancelAdjustmentEdit()
            isMaskInteracting = false
            return nil
        }
        return addMask(shape)
    }

    /// Ends a drag begun with `beginGradient`, or a drag of a handle.
    func endMaskDrag(keepingTool: Bool = false) {
        endAdjustmentEdit()
        isMaskInteracting = false
        if !keepingTool { maskTool = .none }
        refreshPreview()
    }

    func beginMaskDrag(label: String) {
        beginAdjustmentEdit()
        nextHistoryLabel = label
        isMaskInteracting = true
    }

    // MARK: - Painting

    /// Starts a brush stroke at `point`, on the selected brush or a new one.
    func beginBrushStroke(at point: NormalizedPoint, erasing: Bool) {
        guard selectedAsset?.kind == .photo else { return }
        let erase = erasing || brushErasing
        let stroke = BrushStroke(points: [point], size: brushSize, feather: brushFeather, isErase: erase)

        beginAdjustmentEdit()
        nextHistoryLabel = erase ? "Erase" : "Brush"
        isMaskInteracting = true

        if let mask = selectedMask, !mask.shape.isGradient {
            updateMask(mask.id) { mask in
                switch mask.shape {
                case .brush(var strokes):
                    strokes.append(stroke)
                    mask.shape = .brush(strokes: strokes)
                case .subject(var subject):
                    subject.strokes.append(stroke)
                    mask.shape = .subject(subject)
                case .sky(var sky):
                    sky.strokes.append(stroke)
                    mask.shape = .sky(sky)
                default: break
                }
            }
        } else if !erase {
            addMask(.brush(strokes: [stroke]))
        } else {
            // Nothing to erase from yet.
            cancelAdjustmentEdit()
            isMaskInteracting = false
        }
    }

    func extendBrushStroke(to point: NormalizedPoint) {
        guard let mask = selectedMask else { return }
        let strokes: [BrushStroke]
        switch mask.shape {
        case .brush(let value): strokes = value
        case .subject(let value), .sky(let value): strokes = value.strokes
        default: return
        }
        guard let last = strokes.last?.points.last else { return }
        // Points closer than a twentieth of the brush add nothing to the stroke.
        let spacing = (brushSize / 20)
        guard hypot(point.x - last.x, point.y - last.y) >= spacing * 0.5 else { return }
        updateMask(mask.id) { mask in
            if case .brush(var strokes) = mask.shape, !strokes.isEmpty {
                strokes[strokes.count - 1].points.append(point)
                mask.shape = .brush(strokes: strokes)
            } else if var subject = mask.shape.rasterSelection, !subject.strokes.isEmpty {
                subject.strokes[subject.strokes.count - 1].points.append(point)
                mask.shape.rasterSelection = subject
            }
        }
    }

    func endBrushStroke() {
        endAdjustmentEdit()
        isMaskInteracting = false
        refreshPreview()
    }

    // MARK: - Keys

    /// Mask keys in Develop: O shows the overlay, [ and ] resize the brush, Esc closes the tool.
    func handleMaskKey(_ characters: String) -> Bool {
        guard workspace == .photo, selectedAsset?.kind == .photo else { return false }
        switch characters {
        case "o", "O":
            guard isMaskEditing else { return false }
            toggleMaskOverlay()
            return true
        case "[":
            guard maskTool == .brush || selectedMask?.shape.isGradient == false else { return false }
            resizeBrush(by: 1 / 1.2)
            return true
        case "]":
            guard maskTool == .brush || selectedMask?.shape.isGradient == false else { return false }
            resizeBrush(by: 1.2)
            return true
        case "\u{1B}":
            return cancelMaskEditing()
        default:
            return false
        }
    }
}
