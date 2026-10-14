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
        .sheet(isPresented: $store.isShowingImportSheet) {
            ImportSheet()
                .environmentObject(store)
        }
        .sheet(isPresented: $store.isShowingSavePresetSheet) {
            SavePresetSheet()
                .environmentObject(store)
        }
        .sheet(item: Binding(
            get: { store.copySheetMode.map(CopySheetItem.init) },
            set: { store.copySheetMode = $0?.mode }
        )) { item in
            CopySettingsSheet(mode: item.mode)
                .environmentObject(store)
        }
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

            Picker("Workspace", selection: Binding(
                get: { store.workspace },
                set: { store.requestWorkspaceChange(to: $0) }
            )) {
                ForEach(Workspace.allCases) { workspace in
                    Text(workspace.rawValue.uppercased()).tag(workspace)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 490)

            Spacer()

            Menu {
                Button("Import from Card or Folder…") { store.showImportSheet() }
                Button("Add Files in Place…") { store.importMedia() }
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            } primaryAction: {
                store.showImportSheet()
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(store.ingest.isRunning)

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
        case .cull:
            CullWorkspace()
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
                .fill(saveStateColor)
                .frame(width: 7, height: 7)
            Text(store.statusMessage)
            Spacer()
            switch store.projectSaveState {
            case .failed(let message):
                Label("Project not saved", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .help(message)
                Button("Retry Save") { store.saveProject() }
                Button("Save As…") { store.saveProject(saveAs: true) }
            case .unsaved:
                Label("Not saved", systemImage: "circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
                    .imageScale(.small)
            case .pending:
                Label("Unsaved changes", systemImage: "circle.fill")
                    .foregroundStyle(.orange)
            case .saved:
                EmptyView()
            }
            Text("V0.4 LIBRARY + CULLING")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var saveStateColor: Color {
        switch store.projectSaveState {
        case .failed: .red
        case .unsaved, .pending: .orange
        case .saved: .green
        }
    }
}

private struct CopySheetItem: Identifiable {
    let mode: CopySheetMode
    var id: String { mode == .copy ? "copy" : "sync" }
}
