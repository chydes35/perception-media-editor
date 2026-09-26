import SwiftUI

@main
struct PerceptionEditorApp: App {
    @StateObject private var store = EditorStore()

    var body: some Scene {
        WindowGroup("Perception Media Editor") {
            RootView()
                .environmentObject(store)
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
                Button("Show Original") { store.setShowingOriginal(true) }
                    .keyboardShortcut("\\", modifiers: [])
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
