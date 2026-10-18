import SwiftUI

struct VideoWorkspace: View {
    @EnvironmentObject private var store: EditorStore

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                VideoMediaBin()
                    .frame(minWidth: 220, idealWidth: 250, maxWidth: 310)
                VideoViewer(showsScopePanel: true)
                    .frame(minWidth: 540, maxWidth: .infinity, maxHeight: .infinity)
                inspector
                    .frame(minWidth: 250, idealWidth: 280, maxWidth: 330)
            }

            Divider()

            VideoTimeline()
                .frame(height: 224)
        }
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label("INSPECTOR", systemImage: "slider.horizontal.3")
                    .font(.caption.weight(.bold))
                    .tracking(1.1)
                    .foregroundStyle(.secondary)

                if let asset = store.selectedVideoAsset {
                    inspectorSection("MEDIA") {
                        metadataRow("Name", asset.filename)
                        metadataRow("Duration", formatTime(asset.durationSeconds ?? 0))
                        if let width = asset.pixelWidth, let height = asset.pixelHeight {
                            metadataRow("Frame", "\(width) × \(height)")
                        }
                        metadataRow("Type", asset.url.pathExtension.uppercased())
                        if let color = asset.sourceColor {
                            metadataRow("Color", color.summary)
                        }
                        if asset.kind == .video {
                            SourceColorPicker(asset: asset)
                        }
                    }
                }

                if let clip = store.selectedTimelineClip {
                    inspectorSection("TIMELINE CLIP") {
                        metadataRow("Start", formatTime(store.project.timelineStartSeconds(of: clip)))
                        metadataRow("Source In", formatTime(clip.sourceStartSeconds))
                        metadataRow("Duration", formatTime(clip.durationSeconds))

                        HStack {
                            Button("− In") { store.trimSelectedClipStart(by: -1) }
                            Button("+ In") { store.trimSelectedClipStart(by: 1) }
                            Button("− Out") { store.trimSelectedClipEnd(by: -1) }
                            Button("+ Out") { store.trimSelectedClipEnd(by: 1) }
                        }
                        .controlSize(.small)

                        HStack {
                            Button("Split", systemImage: "scissors") { store.splitSelectedClip() }
                            Button(clip.isMuted ? "Unmute" : "Mute", systemImage: "speaker.slash") {
                                store.toggleSelectedClipMute()
                            }
                        }
                        .controlSize(.small)
                    }

                    inspectorSection("CLIP AUDIO") {
                        HStack {
                            Text(clip.isMuted ? "Muted" : "Timeline mix")
                                .font(.caption)
                                .foregroundStyle(clip.isMuted ? .orange : .secondary)
                            Spacer()
                            Button("Reset", systemImage: "arrow.counterclockwise") {
                                store.resetSelectedAudioAdjustments()
                            }
                            .controlSize(.small)
                        }

                        audioAdjustment(
                            "Gain",
                            keyPath: \.gainDecibels,
                            range: ClipAudioAdjustments.gainRange,
                            display: { $0 <= ClipAudioAdjustments.minimumGainDecibels ? "Off" : String(format: "%+.1f dB", $0) }
                        )
                        audioAdjustment(
                            "Fade In",
                            keyPath: \.fadeInSeconds,
                            range: 0...max(0.01, clip.durationSeconds / 2),
                            display: { String(format: "%.1fs", $0) }
                        )
                        audioAdjustment(
                            "Fade Out",
                            keyPath: \.fadeOutSeconds,
                            range: 0...max(0.01, clip.durationSeconds / 2),
                            display: { String(format: "%.1fs", $0) }
                        )
                    }
                } else {
                    Text("Select a timeline clip to trim, split, or reorder it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !store.timelinePlaybackWarnings.isEmpty {
                    inspectorSection("PLAYBACK WARNINGS") {
                        ForEach(store.timelinePlaybackWarnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .padding(15)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func inspectorSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.caption2.weight(.bold))
                .tracking(1)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func metadataRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(value)
        }
        .font(.caption)
    }

    private func audioAdjustment(
        _ label: String,
        keyPath: WritableKeyPath<ClipAudioAdjustments, Double>,
        range: ClosedRange<Double>,
        display: (Double) -> String
    ) -> some View {
        let value = store.selectedAudioAdjustments[keyPath: keyPath]
        return VStack(spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption)
                Spacer()
                Text(display(value))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
            Slider(
                value: Binding(
                    get: { store.selectedAudioAdjustments[keyPath: keyPath] },
                    set: { newValue in
                        store.updateSelectedAudioAdjustments { $0[keyPath: keyPath] = newValue }
                    }
                ),
                in: range
            )
            .tint(.blue)
        }
     }
}
