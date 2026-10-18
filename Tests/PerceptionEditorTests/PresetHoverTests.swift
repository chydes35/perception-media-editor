import Foundation
import Testing
@testable import PerceptionEditor

private actor RenderLog {
    private(set) var adjustments: [PhotoAdjustments] = []
    func record(_ value: PhotoAdjustments) { adjustments.append(value) }
}

struct PresetReplaceLookTests {
    private func preset() -> PhotoPreset {
        PhotoPreset(name: "P", category: "T", adjustments: PhotoAdjustments(contrast: 0.5), groups: [.tone])
    }

    private func edited() -> PhotoAdjustments {
        var a = PhotoAdjustments(exposure: 0.3)
        var grade = ColorGradeAdjustments()
        grade.shadows = GradeZone(hue: 200, saturation: 0.5, luminance: 0)
        a.grading = grade
        a.raw.temperature = 4800
        a.cropAspect = .square
        return a
    }

    @MainActor @Test func presetsStackByDefaultAndReplaceWhenAsked() {
        let stacked = EditorStore.result(of: preset(), on: edited(), amount: 1, replacesLook: false)
        #expect(stacked.grading != nil, "groups the preset does not set keep their earlier values")

        let replaced = EditorStore.result(of: preset(), on: edited(), amount: 1, replacesLook: true)
        #expect(replaced.grading == nil && replaced.exposure == 0, "the earlier look is cleared")
        #expect(replaced.contrast == 0.5)
        #expect(replaced.raw.temperature == 4800 && replaced.cropAspect == .square, "white balance and crop stay")
    }
}

@MainActor
struct PresetHoverPreviewTests {
    private func makeStore(log: RenderLog) -> EditorStore {
        let defaults = UserDefaults(suiteName: "pme-hover-\(UUID())")!
        let store = EditorStore(
            presetRepository: UserPresetRepository(defaults: defaults),
            previewRenderOperation: { _, adjustments, _, _ in
                await log.record(adjustments)
                return (nil, nil)
            }
        )
        let asset = MediaAsset(url: URL(fileURLWithPath: "/Volumes/Test/hover.jpg"))
        store.project.media = [asset]
        store.select(asset)
        store.workspace = .photo
        return store
    }

    @Test func hoveringShowsThePresetWithoutChangingThePhoto() async throws {
        let log = RenderLog()
        let store = makeStore(log: log)
        let preset = PhotoPreset(name: "P", category: "T", adjustments: PhotoAdjustments(contrast: 0.5), groups: [.tone])
        let before = store.selectedAdjustments
        let historyBefore = store.selectedHistory.count

        store.hoverPreset(preset, isHovering: true)
        try await Task.sleep(for: .milliseconds(500))
        #expect(store.presetPreview?.id == preset.id)
        #expect(await log.adjustments.contains { $0.contrast == 0.5 }, "the preview is rendered with the preset")
        #expect(store.selectedAdjustments == before, "the photo's own settings are untouched")
        #expect(store.selectedHistory.count == historyBefore, "and nothing is added to history")

        store.hoverPreset(preset, isHovering: false)
        try await Task.sleep(for: .milliseconds(400))
        #expect(store.presetPreview == nil)
        #expect(await log.adjustments.last?.contrast == 0, "leaving restores the real photo")
    }

    @Test func clickingAppliesAndEndsThePreview() async throws {
        let log = RenderLog()
        let store = makeStore(log: log)
        let preset = PhotoPreset(name: "P", category: "T", adjustments: PhotoAdjustments(contrast: 0.5), groups: [.tone])
        store.hoverPreset(preset, isHovering: true)
        try await Task.sleep(for: .milliseconds(400))
        store.apply(preset)
        #expect(store.presetPreview == nil)
        #expect(store.selectedAdjustments.contrast == 0.5)
    }
}
