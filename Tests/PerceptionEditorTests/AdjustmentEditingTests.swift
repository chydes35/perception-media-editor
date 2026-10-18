import Foundation
import Testing
@testable import PerceptionEditor

@MainActor
struct AdjustmentEditingTests {
    private func makeStore() -> (store: EditorStore, photo: MediaAsset, clip: TimelineClip) {
        let suite = "pme-tests-\(UUID().uuidString)"
        let store = EditorStore(presetRepository: UserPresetRepository(defaults: UserDefaults(suiteName: suite)!))
        let photo = MediaAsset(url: URL(fileURLWithPath: "/Volumes/Test/P1000.RW2"), pixelWidth: 6000, pixelHeight: 4000)
        let video = MediaAsset(url: URL(fileURLWithPath: "/Volumes/Test/C0001.MP4"))
        let clip = TimelineClip(assetID: video.id, sourceStartFrame: 0, durationFrames: 120)
        store.project.media = [photo, video]
        store.project.adjustmentsByAssetID[photo.id] = .neutral
        store.project.timelineClips = [clip]
        store.select(photo)
        store.selectedTimelineClipID = clip.id
        return (store, photo, clip)
    }

    @Test func videoCurveEditsLandOnTheSelectedClip() {
        let (store, photo, clip) = makeStore()
        let editing = store.videoAdjustmentEditing
        let curve = ToneCurve(points: [
            CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.65), CurvePoint(x: 1, y: 1)
        ])

        editing.setCurve(curve, channel: .rgb)

        #expect(store.project.videoAdjustmentsByClipID[clip.id]?.curves[.rgb] == curve)
        #expect(store.selectedVideoAdjustments.curves[.rgb] == curve)
        #expect(store.project.adjustmentsByAssetID[photo.id]?.curves.isNeutral == true)

        store.videoAdjustmentEditing.setHSL(0.4, band: .red, keyPath: \.saturation)
        #expect(store.project.videoAdjustmentsByClipID[clip.id]?.hsl?[.red].saturation == 0.4)
        #expect(store.project.adjustmentsByAssetID[photo.id]?.hsl == nil)
        #expect(store.videoAdjustmentEditing.current.curves[.rgb] == curve)
    }

    @Test func photoEditorStillEditsThePhoto() {
        let (store, photo, clip) = makeStore()
        let editing = store.photoAdjustmentEditing
        let curve = ToneCurve(points: [
            CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.35), CurvePoint(x: 1, y: 1)
        ])

        editing.setCurve(curve, channel: .red)
        store.photoAdjustmentEditing.setHSL(-0.3, band: .blue, keyPath: \.hue)

        #expect(store.selectedAdjustments.curves[.red] == curve)
        #expect(store.project.adjustmentsByAssetID[photo.id]?.hsl?[.blue].hue == -0.3)
        #expect(store.project.videoAdjustmentsByClipID[clip.id] == nil)
        #expect(store.photoAdjustmentEditing.current == store.selectedAdjustments)

        store.photoAdjustmentEditing.resetCurves()
        store.photoAdjustmentEditing.resetHSL()
        #expect(store.selectedAdjustments.curves.isNeutral)
        #expect(store.selectedAdjustments.hsl == nil)
    }

    @Test func aVideoEditingValueBuiltOnceSeesItsOwnEarlierEdits() {
        let (store, _, clip) = makeStore()
        let editing = store.videoAdjustmentEditing   // built once, like an injected environment value

        var curve = editing.current.curves[.rgb] ?? .linear
        let index = curve.addPoint(x: 0.5, y: curve.evaluate(0.5))
        editing.setCurve(curve, channel: .rgb)
        #expect(editing.current.curves[.rgb]?.points.count == 3, "current reads live, not a snapshot")

        var moved = editing.current.curves[.rgb] ?? .linear
        moved.movePoint(at: index ?? 1, to: CGPoint(x: 0.5, y: 0.8))
        editing.setCurve(moved, channel: .rgb)

        let stored = store.project.videoAdjustmentsByClipID[clip.id]?.curves[.rgb]
        #expect(stored?.points.count == 3)
        #expect(stored?.points.contains { abs($0.y - 0.8) < 1e-9 } == true)
    }

    @Test func aVideoEditLeavesPhotoUndoHistoryUntouched() {
        let (store, _, _) = makeStore()
        let before = (store.canUndoPhotoEdit, store.history.count)
        store.videoAdjustmentEditing.beginEdit()
        store.videoAdjustmentEditing.setCurve(.linear, channel: .rgb)
        store.videoAdjustmentEditing.setHSL(0.2, band: .red, keyPath: \.hue)
        store.videoAdjustmentEditing.endEdit()
        #expect(store.canUndoPhotoEdit == before.0)
        #expect(store.history.count == before.1)
    }
}
