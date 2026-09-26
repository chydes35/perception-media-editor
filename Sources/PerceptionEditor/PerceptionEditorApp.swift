import AppKit
import SwiftUI

@main
struct PerceptionEditorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = EditorStore()

    var body: some Scene {
        WindowGroup("Perception Media Editor") {
            RootView()
                .environmentObject(store)
                .onAppear { appDelegate.store = store }
        }
        .defaultSize(width: 1380, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project") { store.newProject() }
                    .keyboardShortcut("n")
                Button("Open Project…") { store.openProject() }
                    .keyboardShortcut("o")
                Divider()
                Button("Import Media…") { store.importMedia() }
                    .keyboardShortcut("i")
                Divider()
                Button("Save Project") { store.saveProject() }
                    .keyboardShortcut("s")
                Button("Save Project As…") { store.saveProject(saveAs: true) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }

            CommandMenu("Photo") {
                // Photo undo covers photo adjustments only, so it stays out of the video timeline.
                Button("Undo Photo Edit") { store.undoPhotoEdit() }
                    .keyboardShortcut("z")
                    .disabled(!store.canUndoPhotoEdit || store.workspace == .video)
                Button("Redo Photo Edit") { store.redoPhotoEdit() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!store.canRedoPhotoEdit || store.workspace == .video)
                Divider()
                // `\` toggles before/after through AppDelegate's key monitor, which leaves
                // the key alone while a text field is being edited.
                Button("Toggle Before/After  \\") { store.toggleBeforeAfter() }
                    .disabled(store.workspace != .photo || store.selectedAsset == nil)
                Button("Show Original") { store.setShowingOriginal(true) }
                Button("Show Edited") { store.setShowingOriginal(false) }
                Divider()
                Button("Reset Adjustments") { store.resetAdjustments() }
            }

            CommandMenu("Workspace") {
                ForEach(Workspace.allCases) { workspace in
                    Button(workspace.rawValue) { store.workspace = workspace }
                }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: EditorStore?
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyDown(event) ? nil : event
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        return store.confirmDiscardingUnsavedChanges() ? .terminateNow : .terminateCancel
    }

    /// Single-key editor shortcuts. They are ignored while any text field or text view has
    /// focus, so typing never triggers an edit.
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.isDisjoint(with: [.command, .control, .option]),
              !(event.window?.firstResponder is NSText),
              let store
        else { return false }

        switch event.charactersIgnoringModifiers {
        case "\\":
            guard store.workspace == .photo, store.selectedAsset != nil else { return false }
            store.toggleBeforeAfter()
            return true
        default:
            return false
        }
    }
}
