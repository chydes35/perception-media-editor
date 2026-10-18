@preconcurrency import AVFoundation
import Foundation
import Metal
import Testing
@testable import PerceptionEditor

@Suite(.serialized)
@MainActor
struct EditorNavigationTests {
    @Test func photoStepsAreImportCullDevelopExport() {
        let steps = EditorCategory.photo.steps
        #expect(steps.map(\.title) == ["Import", "Cull", "Develop", "Export"])
        #expect(steps.map(\.workspace) == [.library, .cull, .photo, .export])
    }

    @Test func videoStepsAreImportCutColorAudioExport() {
        let steps = EditorCategory.video.steps
        #expect(steps.map(\.title) == ["Import", "Cut", "Color", "Audio", "Export"])
        #expect(steps.map(\.workspace) == [.library, .video, .videoColor, .videoAudio, .videoExport])
    }

    @Test func audioStepIsInTheVideoRail() {
        let steps = EditorCategory.video.steps
        let color = steps.firstIndex { $0.workspace == .videoColor }
        let audio = steps.firstIndex { $0.workspace == .videoAudio }
        #expect(audio != nil)
        #expect(audio == color.map { $0 + 1 }, "Audio comes right after Color")
        #expect(steps.first { $0.workspace == .videoAudio }?.title == "Audio")
        #expect(Workspace.videoAudio.isVideo)
        #expect(Workspace.videoAudio.category == .video)
        #expect(!EditorCategory.photo.steps.contains { $0.workspace == .videoAudio })
        #expect(EditorStepShortcut.all.contains { $0.step.workspace == .videoAudio })
    }

    @Test func colorStepIsInTheVideoRail() {
        let steps = EditorCategory.video.steps
        let cut = steps.firstIndex { $0.workspace == .video }
        let color = steps.firstIndex { $0.workspace == .videoColor }
        #expect(color != nil)
        #expect(color == cut.map { $0 + 1 }, "Color comes right after Cut")
        #expect(steps.first { $0.workspace == .videoColor }?.title == "Color")
        #expect(Workspace.videoColor.isVideo)
        #expect(Workspace.videoColor.category == .video)
        #expect(!EditorCategory.photo.steps.contains { $0.workspace == .videoColor })
        #expect(EditorStepShortcut.all.contains { $0.step.workspace == .videoColor })
    }

    private func makeVideoStore(_ temp: TempDirectory) throws -> EditorStore {
        let suite = "pme-color-tests-\(UUID().uuidString)"
        return EditorStore(
            presetRepository: UserPresetRepository(defaults: UserDefaults(suiteName: suite)!),
            proxyStore: ProxyStore(directory: try temp.subdirectory("Proxy Cache"), availableBytes: { _ in 1 << 40 }),
            proxyDefaults: UserDefaults(suiteName: suite)!,
            lutLibrary: LUTLibrary(directory: temp.url.appendingPathComponent("Library"))
        )
    }

    /// A store with one clip on the timeline, selected. Its file exists (this source file) but is
    /// not a movie, so playback builds fail quietly.
    private func storeWithSelectedClip() -> EditorStore {
        let store = EditorStore()
        let video = MediaAsset(url: URL(fileURLWithPath: #filePath), kind: .video)
        let clip = TimelineClip(assetID: video.id, sourceStartFrame: 0, durationFrames: 120)
        store.project.media = [video]
        store.project.timelineClips = [clip]
        store.selectedTimelineClipID = clip.id
        return store
    }

    @Test func scopesRunOnlyWhileTheColorScreenIsShown() async {
        let store = storeWithSelectedClip()
        store.workspace = .video
        #expect(!store.scopesVisible)
        store.requestStepChange(EditorCategory.video.steps[2])
        await store.workspaceChangeTask?.value
        #expect(store.workspace == .videoColor)
        #expect(store.scopesVisible, "Color turns the scopes on")
        store.requestStepChange(EditorCategory.video.steps[1])
        await store.workspaceChangeTask?.value
        #expect(!store.scopesVisible, "Leaving restores the earlier off state")

        // Scopes already open on Cut stay open after a visit to Color.
        store.scopesVisible = true
        store.workspace = .videoColor
        #expect(store.scopesVisible)
        store.workspace = .videoExport
        #expect(store.scopesVisible)
        store.scopesVisible = false
    }

    @Test func colorWithNoClipShowsAnEmptyState() {
        let store = EditorStore()
        store.workspace = .videoColor
        #expect(!store.colorHasTarget)
        #expect(!store.scopesVisible, "No clip, no scope capture")
        #expect(!store.videoAdjustmentEditing.isAvailable)

        // Scopes left open on Cut are not running on an empty Color screen either.
        let open = EditorStore()
        open.workspace = .video
        open.scopesVisible = true
        open.workspace = .videoColor
        #expect(!open.scopesVisible)
        open.workspace = .video
        #expect(open.scopesVisible)
        open.scopesVisible = false
    }

    @Test func selectingAClipOnTheColorScreenStartsTheScopes() {
        let store = storeWithSelectedClip()
        let clipID = store.selectedTimelineClipID
        store.selectedTimelineClipID = nil
        store.workspace = .videoColor
        #expect(!store.scopesVisible)
        store.selectedTimelineClipID = clipID
        #expect(store.colorHasTarget)
        #expect(store.scopesVisible)
        store.workspace = .video
        #expect(!store.scopesVisible)
    }

    @Test func colorWithOfflineMediaShowsAnEmptyState() {
        let store = EditorStore()
        let offline = MediaAsset(url: URL(fileURLWithPath: "/Volumes/Gone/C0001.MOV"), kind: .video)
        let clip = TimelineClip(assetID: offline.id, sourceStartFrame: 0, durationFrames: 120)
        store.project.media = [offline]
        store.project.timelineClips = [clip]
        store.selectedTimelineClipID = clip.id
        store.workspace = .videoColor
        #expect(!store.colorHasTarget)
        #expect(store.colorEmptyReason == .offline)
        #expect(!store.scopesVisible, "Offline media runs no scopes")

        // A clip whose asset left the project is not gradable either.
        let orphan = TimelineClip(assetID: UUID(), sourceStartFrame: 0, durationFrames: 24)
        store.project.timelineClips = [orphan]
        store.selectedTimelineClipID = orphan.id
        #expect(store.colorEmptyReason == .offline)
        #expect(!store.scopesVisible)

        store.selectedTimelineClipID = nil
        #expect(store.colorEmptyReason == .noSelection)
        store.project.timelineClips = []
        #expect(store.colorEmptyReason == .noClips)
        store.workspace = .video
    }

    @Test func leavingColorRebuildsPlaybackOnceAndNotOffTheVideoScreens() {
        let store = storeWithSelectedClip()
        store.workspace = .videoColor
        store.videoBeforeAfter = true
        let built = store.playbackBuildCount
        store.workspace = .photo
        #expect(store.playbackBuildCount == built, "No preview is built for a screen that shows none")
        #expect(!store.videoBeforeAfter)
        #expect(!store.scopesVisible)
        store.workspace = .video
        #expect(store.playbackBuildCount == built + 1, "The stale preview is rebuilt once on return")

        store.workspace = .videoColor
        store.videoBeforeAfter = true
        let again = store.playbackBuildCount
        store.workspace = .video
        #expect(store.playbackBuildCount == again + 1, "Before/after and scopes change in one rebuild")
    }

    @Test func leavingColorTurnsBeforeAfterOff() {
        let store = storeWithSelectedClip()
        store.workspace = .videoColor
        store.videoBeforeAfter = true
        store.workspace = .video
        #expect(!store.videoBeforeAfter)
    }

    @Test func colorChipsShowAndHideTheirPanes() {
        let store = EditorStore()
        #expect(store.colorScopeShowsHistogram)
        #expect(store.colorScopeShowsVectorscope)
        store.colorScopeShowsHistogram.toggle()
        #expect(!store.colorScopeShowsHistogram)
        store.setWaveformMode(.rgbParade)
        #expect(store.scopeModel.waveformMode == .rgbParade)
        store.setWaveformMode(.luma)
        #expect(store.scopeModel.waveformMode == .luma)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func beforeAfterBuildsANeutralPreviewRecipe() async throws {
        let temp = try TempDirectory()
        let store = try makeVideoStore(temp)
        let movie = try await writeColorPatternMovie(to: temp.url.appendingPathComponent("A.MOV"))
        await store.importURLs([movie]).value
        store.proxyStore.cancelAll()
        let asset = try #require(store.project.media.first)
        store.setColorInput(.aces, forAssets: [asset.id])
        store.workspace = .videoColor
        store.addToTimeline(asset)
        let clipID = try #require(store.selectedTimelineClipID)
        store.updateSelectedVideoAdjustments { $0.exposure = 1 }

        func recipe() -> ClipRenderRecipe? {
            (store.videoPlayer?.currentItem?.videoComposition?.instructions ?? [])
                .compactMap { ($0 as? TimelineCompositionInstruction)?.recipe }.first
        }
        try await waitUntil { store.isTimelinePlayback && recipe()?.adjustments.exposure == 1 }
        #expect(recipe()?.ocioInput != nil, "Graded preview carries the source-color transform")

        store.videoBeforeAfter = true
        try await waitUntil { store.isTimelinePlayback && recipe()?.adjustments == .neutral }
        let before = try #require(recipe())
        #expect(before.adjustments == .neutral)
        #expect(before.inputLUT == nil)
        #expect(before.ocioInput == nil)
        #expect(store.project.videoAdjustmentsByClipID[clipID]?.exposure == 1, "The grade itself is untouched")
        #expect(store.project.colorInput(for: asset.id) == .aces)

        store.videoBeforeAfter = false
        try await waitUntil { store.isTimelinePlayback && recipe()?.adjustments.exposure == 1 }
        #expect(recipe()?.ocioInput != nil)
        store.workspace = .video
        store.proxyStore.cancelAll()
    }

    @Test func changingCategoryReturnsToTheLastStepUsedThere() async {
        let store = EditorStore()
        store.workspace = .cull
        #expect(store.category == .photo)
        store.requestCategoryChange(to: .video)
        await store.workspaceChangeTask?.value
        #expect(store.category == .video)
        store.requestCategoryChange(to: .photo)
        await store.workspaceChangeTask?.value
        #expect(store.category == .photo)
        #expect(store.workspace == .cull)
    }

    @Test func requestStepChangeNavigatesToTheStepWorkspace() async {
        let store = EditorStore()
        store.requestStepChange(EditorCategory.photo.steps[2])
        await store.workspaceChangeTask?.value
        #expect(store.workspace == .photo)
    }

    @Test func programmaticWorkspaceChangesKeepTheCategoryInSync() {
        let store = EditorStore()
        store.workspace = .cull
        #expect(store.category == .photo)
        store.workspace = .video
        #expect(store.category == .video)
        store.workspace = .library
        #expect(store.category == .video)
        #expect(Workspace.library.category == nil)
        #expect(Workspace.agents.category == nil)
    }

    @Test func agentsReturnsToWhereYouWere() {
        let store = EditorStore()
        store.workspace = .video
        store.openAgents()
        #expect(store.workspace == .agents)
        #expect(store.category == .video)
        store.closeAgents()
        #expect(store.workspace == .video)
    }

    @Test func metricsMeetTheSpecMinimums() {
        #expect(EditorMetrics.railButtonHeight >= 56)
        #expect(EditorMetrics.categoryButtonHeight >= 36)
        #expect(EditorMetrics.railWidth == 96)
    }

    @Test func switchingCategoryPausesVideoPlayback() async {
        let store = EditorStore()
        store.workspace = .video
        store.markVideoPlayingForTesting()
        #expect(store.isVideoPlaying)
        store.requestCategoryChange(to: .photo)
        await store.workspaceChangeTask?.value
        #expect(!store.isVideoPlaying)
    }

    @Test func leavingAVideoScreenForANonVideoScreenPausesPlayback() async {
        let store = EditorStore()
        store.workspace = .video
        store.markVideoPlayingForTesting()
        store.requestWorkspaceChange(to: .cull)
        await store.workspaceChangeTask?.value
        #expect(store.workspace == .cull)
        #expect(!store.isVideoPlaying)
    }

    /// A ten-second synthetic movie imported into a store with a disposable proxy cache.
    private func storeWithMovie(_ temp: TempDirectory) async throws -> (EditorStore, MediaAsset) {
        let store = try makeVideoStore(temp)
        store.usesProxiesForPlayback = false
        let movie = try await writeColorPatternMovie(to: temp.url.appendingPathComponent("A.MOV"), frames: 240)
        await store.importURLs([movie]).value
        store.proxyStore.cancelAll()
        return (store, try #require(store.project.media.first))
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func cutToColorKeepsTimelinePlaybackPlaying() async throws {
        let temp = try TempDirectory()
        let (store, asset) = try await storeWithMovie(temp)
        store.workspace = .video
        store.addToTimeline(asset)
        try await waitUntil { store.isTimelinePlayback && store.timelinePlaybackDurationSeconds > 0 }
        store.toggleVideoPlayback()
        #expect(store.isVideoPlaying)
        let before = store.playbackBuildCount
        store.requestStepChange(EditorCategory.video.steps[2])
        await store.workspaceChangeTask?.value
        #expect(store.workspace == .videoColor)
        #expect(store.playbackBuildCount == before + 1, "Scopes on: one rebuild through the compositor")
        try await waitUntil { store.isTimelinePlayback && store.videoPlayer?.currentItem?.videoComposition?.customVideoCompositorClass != nil }
        #expect(store.isTimelinePlayback)
        #expect(store.videoPlayer?.rate != 0, "Still playing after the rebuild")
        store.workspace = .photo
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func enteringColorFromAPlayingSourcePreviewPlaysTheTimeline() async throws {
        let temp = try TempDirectory()
        let (store, asset) = try await storeWithMovie(temp)
        store.workspace = .video
        store.addToTimeline(asset)
        try await waitUntil { store.isTimelinePlayback && store.timelinePlaybackDurationSeconds > 0 }
        store.selectVideo(asset)
        try await waitUntil { !store.isTimelinePlayback && store.videoPlayer?.currentItem != nil }
        #expect(store.selectedTimelineClipID != nil)
        store.videoPlayer?.play()
        store.markVideoPlayingForTesting()
        let before = store.playbackBuildCount

        store.workspace = .videoColor
        #expect(store.playbackBuildCount == before + 1, "One timeline build; no wasted source rebuild for the scopes")
        #expect(store.scopesVisible)
        try await waitUntil { store.isTimelinePlayback && store.isVideoPlaying }
        #expect(store.isTimelinePlayback)
        #expect(store.videoPlayer?.rate != 0)
        store.workspace = .photo
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func enteringColorFromAPausedSourcePreviewStaysPaused() async throws {
        let temp = try TempDirectory()
        let (store, asset) = try await storeWithMovie(temp)
        store.workspace = .video
        store.addToTimeline(asset)
        try await waitUntil { store.isTimelinePlayback && store.timelinePlaybackDurationSeconds > 0 }
        store.selectVideo(asset)
        try await waitUntil { !store.isTimelinePlayback && store.videoPlayer?.currentItem != nil }
        store.workspace = .videoColor
        try await waitUntil { store.isTimelinePlayback && store.timelinePlaybackDurationSeconds > 0 }
        #expect(!store.isVideoPlaying)
        store.workspace = .photo
    }

    @Test func cutToVideoExportDoesNotPausePlayback() async {
        let store = EditorStore()
        store.workspace = .video
        store.markVideoPlayingForTesting()
        store.requestStepChange(EditorCategory.video.steps[4])
        await store.workspaceChangeTask?.value
        #expect(store.workspace == .videoExport)
        #expect(store.isVideoPlaying)
    }

    @Test func cutToAudioDoesNotPausePlayback() async {
        let store = EditorStore()
        store.workspace = .video
        store.markVideoPlayingForTesting()
        store.requestStepChange(EditorCategory.video.steps[3])
        await store.workspaceChangeTask?.value
        #expect(store.workspace == .videoAudio)
        #expect(store.isVideoPlaying)
    }

    @Test func isVideoCoversEveryVideoScreen() {
        #expect(Workspace.video.isVideo)
        #expect(Workspace.videoColor.isVideo)
        #expect(Workspace.videoAudio.isVideo)
        #expect(Workspace.videoExport.isVideo)
        for workspace in [Workspace.library, .cull, .photo, .export, .agents] {
            #expect(!workspace.isVideo)
        }
    }

    @Test func undoIsDisabledOnVideoScreens() {
        let store = EditorStore()
        let id = UUID()
        _ = store.photoUndoHistory.record(before: [id: .neutral], after: [id: PhotoAdjustments(exposure: 1)])
        store.workspace = .photo
        #expect(store.canUndoPhotoEdit)
        #expect(store.undoMenuEnabled)
        store.workspace = .video
        #expect(!store.undoMenuEnabled)
        store.workspace = .videoExport
        #expect(!store.undoMenuEnabled)
        #expect(!store.redoMenuEnabled)
    }

    @Test func videoImportStepOpensTheLibraryOnVideo() async {
        let store = EditorStore()
        store.requestStepChange(EditorCategory.video.steps[0])
        await store.workspaceChangeTask?.value
        #expect(store.workspace == .library)
        #expect(store.libraryEntrySection == "Video")
        let photo = EditorStore()
        photo.requestStepChange(EditorCategory.photo.steps[0])
        await photo.workspaceChangeTask?.value
        #expect(photo.libraryEntrySection == nil)
    }

    @Test func workspaceMenuShortcutsAreOneToNineAndAgentsUsesZero() {
        #expect(EditorStepShortcut.all.map { String($0.key) } == ["1", "2", "3", "4", "5", "6", "7", "8", "9"])
        #expect(!EditorStepShortcut.all.contains { $0.key == EditorStepShortcut.agentsKey })
        #expect(EditorStepShortcut.agentsKey == "0")
    }

    @Test func menuStepFromDevelopToVideoImportSwitchesCategory() async {
        let store = EditorStore()
        store.workspace = .photo
        store.requestStepChange(EditorCategory.video.steps[0])
        #expect(store.libraryEntrySection == nil)
        await store.workspaceChangeTask?.value
        #expect(store.workspace == .library)
        #expect(store.category == .video)
        #expect(store.libraryEntrySection == "Video")
    }

    @Test func menuStepFromVideoImportToPhotoImportSwitchesCategory() async {
        let store = EditorStore()
        store.requestCategoryChange(to: .video)
        await store.workspaceChangeTask?.value
        #expect(store.workspace == .library)
        #expect(store.category == .video)
        store.requestStepChange(EditorCategory.photo.steps[0])
        await store.workspaceChangeTask?.value
        #expect(store.workspace == .library)
        #expect(store.category == .photo)
        #expect(store.libraryEntrySection == "Photos")
    }

    @Test func menuStepFromVideoCutToPhotoImportSwitchesCategory() async {
        let store = EditorStore()
        store.workspace = .video
        store.requestStepChange(EditorCategory.photo.steps[0])
        await store.workspaceChangeTask?.value
        #expect(store.workspace == .library)
        #expect(store.category == .photo)
    }

    @Test func importStepIsRememberedPerCategory() async {
        let store = EditorStore()
        store.workspace = .video
        store.requestStepChange(EditorCategory.video.steps[0])
        await store.workspaceChangeTask?.value
        #expect(store.workspace == .library)
        store.requestCategoryChange(to: .photo)
        await store.workspaceChangeTask?.value
        store.requestCategoryChange(to: .video)
        await store.workspaceChangeTask?.value
        #expect(store.workspace == .library)
        #expect(store.category == .video)
        store.requestCategoryChange(to: .video)
        await store.workspaceChangeTask?.value
        #expect(store.workspace == .library)
    }

    @Test func photoImportRequestsAPhotoSectionOnReturningFromVideo() async {
        let store = EditorStore()
        store.requestCategoryChange(to: .video)
        await store.workspaceChangeTask?.value
        #expect(store.libraryEntrySection == "Video")
        store.libraryEntrySection = nil
        store.requestCategoryChange(to: .photo)
        await store.workspaceChangeTask?.value
        #expect(store.workspace == .library)
        #expect(store.category == .photo)
        #expect(store.libraryEntrySection == "Photos")
    }

    @Test func autoplayDoesNotStartAfterLeavingTheVideoScreens() {
        let store = EditorStore()
        store.workspace = .video
        store.workspace = .photo
        #expect(!store.beginAutoplay(AVPlayer()))
        #expect(!store.isVideoPlaying)
        store.workspace = .videoExport
        #expect(store.beginAutoplay(AVPlayer()))
        #expect(store.isVideoPlaying)
    }

    @Test func categoryChangeFromCullToVideoLandsOnTheLibraryStep() async {
        let store = EditorStore()
        store.workspace = .cull
        store.requestCategoryChange(to: .video)
        await store.workspaceChangeTask?.value
        #expect(store.workspace == .library)
        #expect(store.category == .video)
    }

    @Test func categoryChangeWhileAlreadyOnTargetStepStillSwitchesCategory() async {
        let store = EditorStore()
        #expect(store.workspace == .library)
        store.requestCategoryChange(to: .video)
        await store.workspaceChangeTask?.value
        #expect(store.workspace == .library)
        #expect(store.category == .video)
    }

    @Test func reachingAgentsThroughWorkspaceRequestStillReturnsCorrectly() async {
        let store = EditorStore()
        store.workspace = .video
        store.requestWorkspaceChange(to: .agents)
        await store.workspaceChangeTask?.value
        #expect(store.workspace == .agents)
        store.closeAgents()
        #expect(store.workspace == .video)
    }

    // MARK: - Audio screen (Task 11)

    /// Records what the stubbed analyzer was asked for.
    private final class AnalyzerCalls: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [(url: URL, range: ClosedRange<Double>?, gain: Double)] = []
        func add(_ url: URL, _ range: ClosedRange<Double>?, _ gain: Double) { lock.withLock { calls.append((url, range, gain)) } }
        var all: [(url: URL, range: ClosedRange<Double>?, gain: Double)] { lock.withLock { calls } }
        var count: Int { all.count }
    }

    /// A stub file whose tone peaks at -3 dBFS and is loud at file times 1.0…1.5 and 3.0…3.2: those
    /// spots clip once the gain reaches +3 dB. Honors the requested range like the real analyzer.
    private func loudSpotsProvider(_ calls: AnalyzerCalls) -> @Sendable (URL, ClosedRange<Double>?, Double) async throws -> AudioLevels {
        { url, range, gain in
            calls.add(url, range, gain)
            let peak = -3 + gain
            let spots: [ClosedRange<Double>] = [1.0 ... 1.5, 3.0 ... 3.2]
            let inside = spots.filter { spot in range.map { spot.overlaps($0) } ?? true }
            return AudioLevels(peakDecibels: peak, clippedRanges: peak >= 0 ? inside : [])
        }
    }

    @Test func clippedSpotsFollowTheMasterAndClipGain() async {
        let store = storeWithSelectedClip()
        let calls = AnalyzerCalls()
        store.audioLevelProvider = loudSpotsProvider(calls)
        store.workspace = .videoAudio
        await store.refreshAudioLevels()
        #expect(store.audioLevels?.clippedRanges.isEmpty == true, "At 0 dB nothing clips")
        #expect(store.audioLevels.map { abs($0.peakDecibels - (-3)) < 1e-9 } == true)

        store.setMasterGainDecibels(6)
        await store.refreshAudioLevels()
        #expect(calls.all.last?.gain == 6, "Master gain is part of the analysis gain")
        #expect(store.audioLevels?.clippedRanges.count == 2)
        #expect(store.audioLevels.map { abs($0.peakDecibels - 3) < 1e-9 } == true)

        store.setMasterGainDecibels(0)
        store.updateSelectedAudioAdjustments { $0.gainDecibels = 4 }
        await store.refreshAudioLevels()
        #expect(calls.all.last?.gain == 4, "Clip gain too")
        #expect(store.audioLevels?.clippedRanges.count == 2)

        store.updateSelectedAudioAdjustments { $0.gainDecibels = -10 }
        await store.refreshAudioLevels()
        #expect(store.audioLevels?.clippedRanges.isEmpty == true, "Lowering the gain clears it")
        store.workspace = .video
    }

    @Test func clippedSpotsAreInTimelineTime() async {
        let store = storeWithSelectedClip()
        let first = store.project.timelineClips[0]
        // A second clip from the same file, from source 1.001 s (24 frames), after the first.
        let second = TimelineClip(assetID: first.assetID, sourceStartFrame: 24, durationFrames: 72)
        store.project.timelineClips.append(second)
        store.project.packTimeline()
        store.project.masterGainDecibels = 6
        let calls = AnalyzerCalls()
        store.audioLevelProvider = loudSpotsProvider(calls)
        await store.refreshAudioLevels()

        #expect(calls.count == 2, "One analysis per clip")
        let secondStart = store.project.timelineStartSeconds(of: store.project.timelineClips[1])
        let ranges = store.audioLevels?.clippedRanges ?? []
        // First clip (source 0…5.005): both spots at their file times. Second clip (source
        // 1.001…4.004, timeline from 5.005): spots clamped to the clip, shifted by start minus source start.
        let offset = secondStart - 1.001
        let expected: [ClosedRange<Double>] = [1.0 ... 1.5, 3.0 ... 3.2, (1.001 + offset) ... (1.5 + offset), (3.0 + offset) ... (3.2 + offset)]
        #expect(ranges.count == expected.count)
        for (range, wanted) in zip(ranges, expected) {
            #expect(abs(range.lowerBound - wanted.lowerBound) < 0.001 && abs(range.upperBound - wanted.upperBound) < 0.001,
                    "\(range) vs \(wanted)")
        }
        #expect(ranges.map(\.lowerBound) == ranges.map(\.lowerBound).sorted(), "Sorted by time")
    }

    @Test func mutedAndSilentClipsAreNotMeasured() async {
        let store = storeWithSelectedClip()
        let calls = AnalyzerCalls()
        store.audioLevelProvider = loudSpotsProvider(calls)
        store.project.timelineClips[0].isMuted = true
        await store.refreshAudioLevels()
        #expect(calls.count == 0, "A muted clip is not heard, so it cannot clip")
        store.project.timelineClips[0].isMuted = false
        store.updateSelectedAudioAdjustments { $0.gainDecibels = ClipAudioAdjustments.minimumGainDecibels }
        await store.refreshAudioLevels()
        #expect(calls.count == 0, "Gain at the floor is silence")
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func jumpToNextClippedSpotMovesThePlayheadAndWraps() async throws {
        let temp = try TempDirectory()
        let (store, asset) = try await storeWithMovie(temp)
        store.workspace = .video
        store.addToTimeline(asset)
        try await waitUntil { store.isTimelinePlayback && store.timelinePlaybackDurationSeconds > 0 }
        store.audioLevelProvider = { _, _, _ in
            AudioLevels(peakDecibels: 2, clippedRanges: [6.0 ... 6.5, 2.0 ... 2.1])
        }
        await store.refreshAudioLevels()
        #expect(store.audioLevels?.clippedRanges.count == 2)
        let frame = store.project.sequenceFrameRate.frameSeconds

        store.seekTimeline(to: 0)
        store.jumpToNextClippedSpot()
        #expect(abs(store.timelinePlaybackPositionSeconds - 2.0) <= frame)
        store.jumpToNextClippedSpot()
        #expect(abs(store.timelinePlaybackPositionSeconds - 6.0) <= frame)
        store.jumpToNextClippedSpot()
        #expect(abs(store.timelinePlaybackPositionSeconds - 2.0) <= frame, "Wraps to the first spot")
        store.seekTimeline(to: 4)
        store.jumpToNextClippedSpot()
        #expect(abs(store.timelinePlaybackPositionSeconds - 6.0) <= frame, "Next after the playhead")
        store.workspace = .photo
    }

    @Test func audioWithNoClipsShowsAnEmptyState() async {
        let calls = AnalyzerCalls()
        let empty = EditorStore()
        empty.audioLevelProvider = loudSpotsProvider(calls)
        empty.workspace = .videoAudio
        #expect(empty.audioEmptyReason == .noClips)
        await empty.refreshAudioLevels()
        #expect(calls.count == 0, "No analysis without clips")
        #expect(empty.audioLevels == nil)
        #expect(!empty.isAnalyzingAudio)
        #expect(!empty.audioMeterModel.isRunning, "No meters on an empty screen")
        empty.jumpToNextClippedSpot()

        // Offline media: nothing to analyze.
        let offline = EditorStore()
        offline.audioLevelProvider = loudSpotsProvider(calls)
        let gone = MediaAsset(url: URL(fileURLWithPath: "/Volumes/Gone/C0001.MOV"), kind: .video)
        offline.project.media = [gone]
        offline.project.timelineClips = [TimelineClip(assetID: gone.id, sourceStartFrame: 0, durationFrames: 120)]
        offline.workspace = .videoAudio
        #expect(offline.audioEmptyReason == .offline)
        await offline.refreshAudioLevels()
        #expect(calls.count == 0)
        #expect(offline.audioLevels == nil)
        offline.workspace = .video

        // A clip with no audio track: the analyzer says so, the screen says so.
        let silent = storeWithSelectedClip()
        silent.audioLevelProvider = { _, _, _ in throw AudioLevelError.noAudio }
        silent.workspace = .videoAudio
        await silent.refreshAudioLevels()
        #expect(silent.audioEmptyReason == .noAudio)
        #expect(silent.audioLevels == nil)
        #expect(!silent.isAnalyzingAudio)
        silent.workspace = .video

        // The real analyzer on a file that is not a movie fails quietly.
        let unreadable = storeWithSelectedClip()
        await unreadable.refreshAudioLevels()
        #expect(unreadable.audioEmptyReason == .noAudio)
        #expect(!unreadable.isAnalyzingAudio)
    }

    @Test func setMasterGainDecibelsClampsAndMarksTheProjectEdited() {
        let store = EditorStore()
        store.lastSavedProject = store.project
        #expect(!store.hasUnsavedChanges)
        store.setMasterGainDecibels(30)
        #expect(store.project.masterGainDecibels == ClipAudioAdjustments.maximumGainDecibels)
        #expect(store.hasUnsavedChanges)
        store.setMasterGainDecibels(-100)
        #expect(store.project.masterGainDecibels == ClipAudioAdjustments.minimumGainDecibels)
        store.setMasterGainDecibels(.nan)
        #expect(store.project.masterGainDecibels == ClipAudioAdjustments.minimumGainDecibels, "NaN is ignored")
        store.setMasterGainDecibels(-3)
        #expect(store.project.masterGainDecibels == -3)
    }

    /// Store-to-composition forwarding of `project.masterGainDecibels`: the preview's audio mix
    /// carries clip gain times master gain, and an export started from the store is quieter by it.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func masterGainReachesThePreviewMixAndTheExport() async throws {
        let temp = try TempDirectory()
        let store = try makeVideoStore(temp)
        store.usesProxiesForPlayback = false
        let url = try await writeTestMovie(to: temp.url.appendingPathComponent("tone.mov"), frames: 48, withAudio: true, toneAmplitude: 0.25)
        await store.importURLs([url]).value
        store.proxyStore.cancelAll()
        let asset = try #require(store.project.media.first)
        store.workspace = .video
        store.addToTimeline(asset)
        store.updateSelectedAudioAdjustments { $0.gainDecibels = 6.0206 }
        store.setMasterGainDecibels(-12.0412)

        func volume() -> Float? {
            guard let parameters = store.videoPlayer?.currentItem?.audioMix?.inputParameters.first else { return nil }
            var start: Float = -1, end: Float = -1
            var range = CMTimeRange.zero
            guard parameters.getVolumeRamp(for: CMTime(seconds: 0.5, preferredTimescale: 600), startVolume: &start, endVolume: &end, timeRange: &range) else { return nil }
            return start
        }
        try await waitUntil { store.isTimelinePlayback && volume().map { abs($0 - 0.5) < 0.001 } == true }
        #expect(abs((volume() ?? 0) - 0.5) < 0.001, "x2 clip times x0.25 master")

        let destination = temp.url.appendingPathComponent("Master.mov")
        store.timelineExportSettings = TimelineExportSettings(preset: .proRes422HQ, size: .timeline)
        let export = try store.startTimelineExport(to: destination)
        await export.value
        let peak = try await mixedAudioPeak(AVPlayerItem(url: destination), audioMix: nil)
        #expect(abs(Double(peak) - 0.125) < 0.005, "Exported tone at 0.25 x 0.5 = 0.125, read \(peak)")
        store.workspace = .photo
    }
}
