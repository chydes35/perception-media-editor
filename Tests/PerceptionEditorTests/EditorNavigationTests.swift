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

    @Test func workspaceMenuListsEveryStepOfBothCategories() {
        let titles = EditorCategory.allCases.flatMap { $0.steps.map(\.id) }
        #expect(titles == ["photo.import", "photo.cull", "photo.develop", "photo.export",
                           "video.import", "video.cut", "video.export"])
        let shortcuts = EditorStepShortcut.all
        #expect(shortcuts.count == 7)
        #expect(Set(shortcuts.map(\.key)).count == 7)
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
