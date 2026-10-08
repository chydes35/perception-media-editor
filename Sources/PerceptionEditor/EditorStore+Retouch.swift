import AppKit

extension EditorStore {
    var retouches: [RetouchStroke] { selectedAdjustments.retouches }

    var selectedRetouch: RetouchStroke? {
        guard let selectedRetouchID else { return nil }
        return retouches.first { $0.id == selectedRetouchID }
    }

    var isRetouchEditing: Bool { retouchTool != nil || selectedRetouch != nil || retouchPickingSource }

    func chooseRetouchTool(_ tool: RetouchKind) {
        guard selectedAsset?.kind == .photo else { return }
        let next = retouchTool == tool ? nil : tool
        if next != nil {
            endMaskEditing()
            exitZoom100()
            cancelCropEditing()
            previewMode = .edited
        }
        retouchTool = next
        retouchPickingSource = next == .clone && cloneSource == nil
        if next != nil { selectedRetouchID = nil }
    }

    func selectRetouch(_ id: UUID?) {
        selectedRetouchID = id
        retouchTool = nil
        retouchPickingSource = false
        if id != nil {
            endMaskEditing()
            exitZoom100()
            cancelCropEditing()
            previewMode = .edited
        }
    }

    func endRetouchEditing() {
        retouchTool = nil
        selectedRetouchID = nil
        retouchPickingSource = false
        cloneSource = nil
    }

    func setCloneSource(_ point: NormalizedPoint) {
        cloneSource = point
        retouchPickingSource = false
    }

    func beginRetouch(at point: NormalizedPoint) {
        guard selectedAsset?.kind == .photo, let kind = retouchTool, let geometry = currentGeometry else { return }
        let source: NormalizedPoint
        if kind == .clone {
            guard let cloneSource else {
                retouchPickingSource = true
                return
            }
            source = cloneSource
        } else {
            source = RetouchStroke.suggestedSource(for: point, size: retouchSize, image: geometry.sourceSize)
        }
        beginAdjustmentEdit()
        nextHistoryLabel = kind.title
        let stroke = RetouchStroke(kind: kind, points: [point], source: source,
                                   size: retouchSize, feather: retouchFeather, opacity: retouchOpacity)
        updateAdjustments { $0.retouches.append(stroke) }
        selectedRetouchID = stroke.id
    }

    func extendRetouch(to point: NormalizedPoint) {
        guard let id = selectedRetouchID, let stroke = selectedRetouch,
              let last = stroke.points.last, let geometry = currentGeometry else { return }
        let dx = (point.x - last.x) * geometry.sourceSize.width
        let dy = (point.y - last.y) * geometry.sourceSize.height
        guard hypot(dx, dy) >= stroke.size * geometry.longSide / 15 else { return }
        updateRetouch(id) { $0.points.append(point) }
    }

    func endRetouchStroke() {
        endAdjustmentEdit()
        // Keep the active tool for consecutive repairs. The last stroke remains selected so its
        // source pin can be moved before the next stroke begins.
    }

    func updateRetouch(_ id: UUID, _ change: (inout RetouchStroke) -> Void) {
        updateAdjustments { adjustments in
            guard let index = adjustments.retouches.firstIndex(where: { $0.id == id }) else { return }
            change(&adjustments.retouches[index])
        }
    }

    func moveRetouchSource(_ id: UUID, to point: NormalizedPoint) {
        updateRetouch(id) { $0.source = point }
        if retouchTool == .clone { cloneSource = point }
    }

    func deleteRetouch(_ id: UUID) {
        nextHistoryLabel = "Delete repair"
        updateAdjustments { $0.retouches.removeAll { $0.id == id } }
        if selectedRetouchID == id { selectedRetouchID = nil }
    }

    func handleRetouchKey(_ characters: String) -> Bool {
        guard workspace == .photo, selectedAsset?.kind == .photo, isRetouchEditing else { return false }
        switch characters {
        case "[":
            retouchSize = max(0.005, retouchSize / 1.2)
            return true
        case "]":
            retouchSize = min(0.3, retouchSize * 1.2)
            return true
        case "\u{1B}":
            endRetouchEditing()
            return true
        default:
            return false
        }
    }
}
