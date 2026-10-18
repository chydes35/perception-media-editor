import AppKit
import SwiftUI

/// The Video category's Export step: timeline export settings, progress and the last-export reveal.
struct VideoExportWorkspace: View {
    @EnvironmentObject private var store: EditorStore

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Export")
                .font(.largeTitle.bold())
            Text("Render the timeline from the camera originals as 10-bit ProRes 422 HQ or HEVC Main10, Rec. 709.")
                .foregroundStyle(.secondary)

            GroupBox("Timeline") {
                HStack {
                    Image(systemName: "film")
                    Text("\(store.project.timelineClips.count) clip\(store.project.timelineClips.count == 1 ? "" : "s") on the timeline")
                    Spacer()
                }
                .padding(8)
            }

            exportControls

            if store.project.timelineClips.isEmpty {
                Text("Add clips in Cut to export the timeline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(36)
        .frame(maxWidth: 560, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var canExport: Bool { !store.project.timelineClips.isEmpty && !store.isExporting }

    @ViewBuilder
    private var exportControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Format", selection: $store.timelineExportSettings.preset) {
                ForEach(TimelineExportPreset.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Size", selection: $store.timelineExportSettings.size) {
                ForEach(TimelineExportSize.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if store.timelineExport.isRunning {
                HStack(spacing: 12) {
                    ProgressView(value: store.timelineExport.fraction)
                        .frame(minWidth: 240)
                    Text("\(Int(store.timelineExport.fraction * 100))%")
                        .font(.system(.body, design: .monospaced))
                    Button("Cancel Export", systemImage: "xmark.circle.fill") { store.cancelTimelineExport() }
                        .help("Stop the export; nothing is left behind")
                }
            } else {
                HStack(spacing: 12) {
                    Button {
                        store.chooseTimelineExportDestination()
                    } label: {
                        Label("Export Timeline…", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canExport)
                    .help("Export from the camera originals: 10-bit ProRes 422 HQ or HEVC Main10, Rec. 709")
                    if case .finished(let url) = store.timelineExport.phase {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } label: {
                            Label("Show Last Export in Finder", systemImage: "folder")
                        }
                    }
                }
            }
        }
        .controlSize(.large)
    }
}
