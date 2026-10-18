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

    @Test func leavingAVideoScreenPausesPlayback() async {
        let store = EditorStore()
        store.workspace = .video
        store.markVideoPlayingForTesting()
        store.requestStepChange(EditorCategory.video.steps[2])
        await store.workspaceChangeTask?.value
        #expect(store.workspace == .videoExport)
        #expect(!store.isVideoPlaying)
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
