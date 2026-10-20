import Foundation
import Testing
@testable import PerceptionEditor

@MainActor
struct ProcessVersionControlTests {
    private func makeStore() -> (store: EditorStore, photo: MediaAsset, video: MediaAsset) {
        let suite = "pme-process-\(UUID().uuidString)"
        let store = EditorStore(presetRepository: UserPresetRepository(defaults: UserDefaults(suiteName: suite)!))
        let photo = MediaAsset(url: URL(fileURLWithPath: "/Volumes/Test/P1000.RW2"), pixelWidth: 6000, pixelHeight: 4000)
        let video = MediaAsset(url: URL(fileURLWithPath: "/Volumes/Test/C0001.MP4"), kind: .video)
        store.project.media = [photo, video]
        store.project.adjustmentsByAssetID[photo.id] = .neutral
        store.select(photo)
        return (store, photo, video)
    }

    @Test func changingTheProcessIsOneUndoStepAndKeepsTheSliders() {
        let (store, photo, _) = makeStore()
        store.updateAdjustments { $0.exposure = 0.4; $0.shadows = 0.3 }
        let before = store.selectedAdjustments
        #expect(before.processVersion == PhotoAdjustments.currentProcessVersion)

        store.setProcessVersion(2)
        let upgraded = store.selectedAdjustments
        #expect(upgraded.processVersion == 2)
        #expect(upgraded.exposure == 0.4 && upgraded.shadows == 0.3, "the sliders keep their values")
        #expect(upgraded.changeSummary(from: before) == "Process")

        store.undoPhotoEdit()
        #expect(store.project.adjustmentsByAssetID[photo.id] == before, "one undo takes the whole change back")
        store.redoPhotoEdit()
        #expect(store.selectedAdjustments.processVersion == 2)
    }

    @Test func settingTheCurrentProcessChangesNothing() {
        let (store, _, _) = makeStore()
        let version = store.selectedAdjustments.processVersion
        let undoDepth = store.canUndoPhotoEdit
        store.setProcessVersion(version)
        #expect(store.canUndoPhotoEdit == undoDepth)
        store.setProcessVersion(99)
        #expect(store.selectedAdjustments.processVersion == version, "an unknown process is refused")
    }

    @Test func videoNeverChangesProcess() {
        let (store, _, video) = makeStore()
        store.select(video)
        store.setProcessVersion(2)
        #expect(store.project.adjustmentsByAssetID[video.id]?.processVersion != 2)
    }
}

struct WhitesBlacksTests {
    @Test func theyRoundTripAndOldFilesDefaultToZero() throws {
        var adjustments = PhotoAdjustments()
        adjustments.processVersion = 2
        adjustments.whites = 0.4
        adjustments.blacks = -0.25
        let data = try JSONEncoder().encode(adjustments)
        let decoded = try JSONDecoder().decode(PhotoAdjustments.self, from: data)
        #expect(decoded.whites == 0.4 && decoded.blacks == -0.25)

        let old = try JSONDecoder().decode(PhotoAdjustments.self, from: Data(#"{ "shadows": 0.2 }"#.utf8))
        #expect(old.whites == 0 && old.blacks == 0)
    }

    @Test func theLightGroupCarriesThem() {
        var source = PhotoAdjustments()
        source.whites = 0.5
        source.blacks = -0.5
        let target = PhotoAdjustments().applying(source, groups: [.tone])
        #expect(target.whites == 0.5 && target.blacks == -0.5)
        #expect(source.editedGroups.contains(.tone))
        #expect(PhotoAdjustments().applying(source, groups: [.color]).whites == 0, "other groups leave them alone")
        #expect(source.changeSummary(from: PhotoAdjustments()) == "Whites, Blacks")
    }

    @Test func presetAmountBlendsThem() {
        var full = PhotoAdjustments()
        full.whites = 0.8
        let half = PhotoAdjustments().applying(full, groups: [.tone], amount: 0.5)
        #expect(abs(half.whites - 0.4) < 1e-9)
    }

    @Test func whitesActOnTheBrightEndAndBlacksOnTheDeepEnd() {
        let ramp = IQFixtures.grayRamp()
        let base = IQRender.photo(ramp, IQRender.version2(), raw: true)
        let whites = IQRender.photo(ramp, IQRender.version2 { $0.whites = -1 }, raw: true)
        let blacks = IQRender.photo(ramp, IQRender.version2 { $0.blacks = 1 }, raw: true)
        func ratio(_ a: [UInt16], _ x: Int) -> Double {
            IQRender.luma(IQRender.linear(a, width: 256, x: x, y: 16)) / IQRender.luma(IQRender.linear(base, width: 256, x: x, y: 16))
        }
        // 2⁻⁹ at x = 18 (deep black); 2⁻⁰·⁵ at x = 173 (bright); 2⁻⁴ at x = 109 (a mid-dark tone).
        #expect(ratio(whites, 173) < 0.8, "whites −1 darkens the bright end")
        #expect(ratio(whites, 18) > 0.97, "and leaves the deep tones")
        #expect(ratio(blacks, 18) > 1.4, "blacks +1 lifts the deep tones")
        #expect(ratio(blacks, 173) < 1.05, "and leaves the bright end")
    }
}
