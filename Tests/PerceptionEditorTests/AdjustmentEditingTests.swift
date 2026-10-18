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
}
