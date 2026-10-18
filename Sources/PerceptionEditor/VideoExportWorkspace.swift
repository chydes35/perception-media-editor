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

            TimelineExportControls()
                .controlSize(.large)

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
}
