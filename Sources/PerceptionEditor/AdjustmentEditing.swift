import SwiftUI

/// What the tone-curve editor and HSL panel edit: one set of adjustments, read and written through
/// closures. A nil environment value means the selected photo; the Video Color screen supplies the
/// selected clip's adjustments instead.
@MainActor
struct AdjustmentEditing {
    var current: PhotoAdjustments
    var update: (@MainActor (inout PhotoAdjustments) -> Void) -> Void
    /// Bracket a drag so it records one undo step. Video clip edits have no undo history, so they do nothing.
    var beginEdit: @MainActor () -> Void = {}
    var endEdit: @MainActor () -> Void = {}
    /// False when nothing is selected to edit.
    var isAvailable = true
    /// The histogram on the store belongs to the selected photo, so only photo editing draws it.
    var showsPhotoHistogram = false

    /// The write path ToneCurveEditor uses for every curve change.
    func setCurve(_ curve: ToneCurve, channel: ToneCurves.Channel) {
        update { $0.curves[channel] = curve }
    }

    func resetCurves() {
        update { $0.curves = ToneCurves() }
    }

    /// The write path HSLPanel uses for every slider change.
    func setHSL(_ value: Double, band: HSLBand, keyPath: WritableKeyPath<HSLBandAdjustment, Double>) {
        update { adjustments in
            var updated = adjustments.hsl ?? HSLAdjustments()
            updated[band][keyPath: keyPath] = value
            adjustments.hsl = updated.isNeutral ? nil : updated
        }
    }

    func resetHSL() {
        update { $0.hsl = nil }
    }
}

private struct AdjustmentEditingKey: EnvironmentKey {
    nonisolated static var defaultValue: AdjustmentEditing? { nil }
}

extension EnvironmentValues {
    /// Nil means the selected photo.
    var adjustmentEditing: AdjustmentEditing? {
        get { self[AdjustmentEditingKey.self] }
        set { self[AdjustmentEditingKey.self] = newValue }
    }
}

extension EditorStore {
    /// The selected timeline clip's adjustments.
    var videoAdjustmentEditing: AdjustmentEditing {
        AdjustmentEditing(
            current: selectedVideoAdjustments,
            update: { [self] change in updateSelectedVideoAdjustments(change) },
            isAvailable: selectedTimelineClipID != nil
        )
    }

    /// The selected photo's adjustments, used when the environment supplies nothing.
    var photoAdjustmentEditing: AdjustmentEditing {
        AdjustmentEditing(
            current: selectedAdjustments,
            update: { [self] change in updateAdjustments(change) },
            beginEdit: { [self] in beginAdjustmentEdit() },
            endEdit: { [self] in endAdjustmentEdit() },
            isAvailable: selectedAsset != nil,
            showsPhotoHistogram: true
        )
    }
}
