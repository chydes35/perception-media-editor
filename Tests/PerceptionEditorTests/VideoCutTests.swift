import Foundation
import Testing
@testable import PerceptionEditor

@Suite(.serialized)
@MainActor
struct VideoCutTests {
    @Test func timecodeFormatPinsTheExistingBehavior() {
        #expect(formatTime(0) == "00:00.00")
        #expect(formatTime(5.256) == "00:05.26")
        #expect(formatTime(59.994) == "00:59.99")
        #expect(formatTime(61.5) == "01:01.50")
        #expect(formatTime(3725.04) == "62:05.04")
        #expect(formatTime(-3) == "00:00.00")
        #expect(formatTime(.nan) == "00:00.00")
        #expect(formatTime(.infinity) == "00:00.00")
        #expect(formatTime(-.infinity) == "00:00.00")
    }

    @Test func applyingAVideoPresetChangesTheSelectedClipNotThePhoto() {
        let store = EditorStore()
        let video = MediaAsset(url: URL(fileURLWithPath: #filePath), kind: .video)
        let clip = TimelineClip(assetID: video.id, sourceStartFrame: 0, durationFrames: 120)
        store.project.media = [video]
        store.project.timelineClips = [clip]
        store.selectedTimelineClipID = clip.id
        let photoBefore = store.project.adjustmentsByAssetID

        var look = PhotoAdjustments()
        look.contrast = 0.4
        look.exposure = 0.5
        let preset = PhotoPreset(name: "Test look", category: "Test", adjustments: look)
        store.applyVideoPreset(preset)

        #expect(store.selectedVideoAdjustments.contrast == 0.4)
        #expect(store.project.adjustmentsByAssetID == photoBefore)
    }
}
