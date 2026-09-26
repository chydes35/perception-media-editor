import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: EditorStore

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            workspace
            Divider()
            statusBar
        }
        .frame(minWidth: 1120, minHeight: 720)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert(
            "Perception Media Editor",
            isPresented: Binding(
                get: { store.lastError != nil },
                set: { if !$0 { store.lastError = nil } }
            ),
            actions: { Button("OK") { store.lastError = nil } },
            message: { Text(store.lastError ?? "Unknown error") }
        )
    }

    private var topBar: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text("PERCEPTION MEDIA")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.8)
                    .foregroundStyle(.secondary)
                TextField("Project name", text: $store.project.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .frame(width: 270)
            }

            Spacer()

            Picker("Workspace", selection: $store.workspace) {
                ForEach(Workspace.allCases) { workspace in
                    Text(workspace.rawValue.uppercased()).tag(workspace)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 410)

            Spacer()

            Button {
                store.importMedia()
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)

            Button {
                store.exportSelectedPhoto()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .disabled(store.isExporting)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var workspace: some View {
        switch store.workspace {
        case .library:
            LibraryWorkspace()
        case .photo:
            PhotoWorkspace()
        case .video:
            VideoWorkspace()
        case .export:
            ExportWorkspace()
        case .agents:
            AgentWorkspace()
        }
    }

    private var statusBar: some View {
        HStack {
            Circle()
                .fill(Color.green)
                .frame(width: 7, height: 7)
            Text(store.statusMessage)
            Spacer()
            if store.hasUnsavedChanges {
                Label("Unsaved changes", systemImage: "circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
                    .imageScale(.small)
            }
            Text("V0.3 AUDIO MIX")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
