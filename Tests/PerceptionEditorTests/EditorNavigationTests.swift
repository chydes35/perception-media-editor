import AVFoundation
import Foundation
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

    @Test func videoStepsStartWithImportCutAndExport() {
        let steps = EditorCategory.video.steps
        #expect(steps.map(\.title) == ["Import", "Cut", "Export"])
        #expect(steps.map(\.workspace) == [.library, .video, .videoExport])
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

    @Test func cutToVideoExportDoesNotPausePlayback() async {
        let store = EditorStore()
        store.workspace = .video
        store.markVideoPlayingForTesting()
        store.requestStepChange(EditorCategory.video.steps[2])
        await store.workspaceChangeTask?.value
        #expect(store.workspace == .videoExport)
        #expect(store.isVideoPlaying)
    }

    @Test func isVideoCoversEveryVideoScreen() {
        #expect(Workspace.video.isVideo)
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

    @Test func workspaceMenuShortcutsAreOneToSevenAndAgentsUsesZero() {
        #expect(EditorStepShortcut.all.map { String($0.key) } == ["1", "2", "3", "4", "5", "6", "7"])
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
