import Combine
import Testing
@testable import PerceptionEditor

@Suite(.serialized)
@MainActor
struct WorkspaceTransitionTests {
    @Test func pickerDefersAllPublicationsUntilViewUpdateReturns() async throws {
        let store = EditorStore()
        var publications = 0
        let observer = store.objectWillChange.sink { publications += 1 }
        store.requestWorkspaceChange(to: .photo)
        #expect(store.workspace == .library)
        #expect(publications == 0)
        await store.workspaceChangeTask?.value
        #expect(store.workspace == .photo)
        #expect(publications > 0)
        #expect(store.workspaceChangeTask == nil)
        withExtendedLifetime(observer) {}
    }

    @Test func newestPickerRequestWinsIncludingReturningToCurrentWorkspace() async {
        let store = EditorStore()
        store.requestWorkspaceChange(to: .photo)
        let obsolete = store.workspaceChangeTask
        store.requestWorkspaceChange(to: .video)
        #expect(obsolete?.isCancelled == true)
        await store.workspaceChangeTask?.value
        #expect(store.workspace == .video)
        store.requestWorkspaceChange(to: .photo)
        let pending = store.workspaceChangeTask
        store.requestWorkspaceChange(to: .video)
        await pending?.value
        #expect(store.workspace == .video)
        #expect(store.workspaceChangeTask == nil)
    }

    @Test func directNavigationSupersedesQueuedPickerTransition() async {
        let store = EditorStore()
        store.requestWorkspaceChange(to: .photo)
        let pending = store.workspaceChangeTask
        store.workspace = .video
        await pending?.value
        #expect(store.workspace == .video)
        #expect(pending?.isCancelled == true)
        #expect(store.workspaceChangeTask == nil)
    }

    @Test func replacementCancelsQueuedPickerTransition() async {
        let store = EditorStore()
        store.requestWorkspaceChange(to: .photo)
        let pending = store.workspaceChangeTask
        store.resetToEmptyProject(named: "Replacement")
        #expect(pending?.isCancelled == true)
        await pending?.value
        #expect(store.workspace == .library)
        #expect(store.workspaceChangeTask == nil)
    }
}
