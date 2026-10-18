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

    @Test func videoStepsAreImportCutColorExport() {
        let steps = EditorCategory.video.steps
        #expect(steps.map(\.title) == ["Import", "Cut", "Color", "Export"])
        #expect(steps.map(\.workspace) == [.library, .video, .videoColor, .videoExport])
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
        store.requestStepChange(EditorCategory.video.steps[3])
        await store.workspaceChangeTask?.value
        #expect(store.workspace == .videoExport)
        #expect(store.isVideoPlaying)
    }

    @Test func isVideoCoversEveryVideoScreen() {
        #expect(Workspace.video.isVideo)
        #expect(Workspace.videoColor.isVideo)
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

    @Test func workspaceMenuShortcutsAreOneToEightAndAgentsUsesZero() {
        #expect(EditorStepShortcut.all.map { String($0.key) } == ["1", "2", "3", "4", "5", "6", "7", "8"])
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
}
