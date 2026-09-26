import AVKit
import SwiftUI

struct VideoWorkspace: View {
    @EnvironmentObject private var store: EditorStore

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                mediaBin
                    .frame(minWidth: 220, idealWidth: 250, maxWidth: 310)
                viewer
                    .frame(minWidth: 540, maxWidth: .infinity, maxHeight: .infinity)
                inspector
                    .frame(minWidth: 250, idealWidth: 280, maxWidth: 330)
            }

            Divider()

            EditorTimelineView()
                .frame(height: 224)
        }
    }

    private var mediaBin: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("MEDIA", systemImage: "film.stack")
                .font(.caption.weight(.bold))
                .tracking(1.1)
                .foregroundStyle(.secondary)

            if store.videoAssets.isEmpty {
                ContentUnavailableView {
                    Label("No video", systemImage: "film")
                } description: {
                    Text("Import MOV or MP4 media to begin.")
                } actions: {
                    Button("Import Video") { store.importMedia() }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(store.videoAssets) { asset in
                            videoCard(asset)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func videoCard(_ asset: MediaAsset) -> some View {
        Button {
            store.selectVideo(asset)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.black)
                    if let image = store.thumbnail(for: asset) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Image(systemName: "film")
                            .font(.title)
                            .foregroundStyle(.secondary)
                    }
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Text(formatTime(asset.durationSeconds ?? 0))
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 3)
                                .background(.black.opacity(0.72), in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(6)
                }
                .aspectRatio(16 / 9, contentMode: .fit)

                Text(asset.filename)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .padding(8)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(
                        store.selectedVideoAssetID == asset.id ? Color.orange : Color.clear,
                        lineWidth: 2
                    )
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Add to Timeline") { store.addToTimeline(asset) }
            Button("Relink Media…") { store.relink(asset) }
        }
    }

    private var viewer: some View {
        VStack(spacing: 0) {
            HStack {
                Text(store.selectedVideoAsset?.filename ?? "No video selected")
                    .font(.callout.weight(.semibold))
                Text(store.isTimelinePlayback ? "TIMELINE" : "SOURCE")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(
                        store.isTimelinePlayback ? Color.orange.opacity(0.22) : Color.secondary.opacity(0.14),
                        in: Capsule()
                    )
                Spacer()
                Button("Preview Timeline", systemImage: "play.rectangle.on.rectangle") {
                    store.previewTimeline()
                }
                .disabled(store.project.timelineClips.isEmpty)
                Button("Add to Timeline", systemImage: "plus.rectangle.on.rectangle") {
                    store.addToTimeline()
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(store.selectedVideoAsset == nil)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(Color(nsColor: .controlBackgroundColor))

            ZStack {
                Color.black
                if let player = store.videoPlayer {
                    VideoPlayer(player: player)
                        .id(ObjectIdentifier(player))
                        .padding(20)
                } else {
                    ContentUnavailableView(
                        "Select a video",
                        systemImage: "play.rectangle",
                        description: Text("Choose media from the bin or import a video.")
                    )
                    .foregroundStyle(.white, .white.opacity(0.62))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            timelineTransport
        }
    }

    private var timelineTransport: some View {
        HStack(spacing: 12) {
            Button {
                store.toggleVideoPlayback()
            } label: {
                Image(systemName: store.isVideoPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .disabled(store.project.timelineClips.isEmpty)

            Text(formatTime(store.timelinePlaybackPositionSeconds))
                .font(.system(size: 10, design: .monospaced))

            Slider(
                value: Binding(
                    get: { store.timelinePlaybackPositionSeconds },
                    set: { store.seekTimeline(to: $0) }
                ),
                in: 0 ... max(0.01, store.timelinePlaybackDurationSeconds)
            )
            .disabled(store.project.timelineClips.isEmpty)
            .accessibilityLabel("Timeline playhead")

            Text(formatTime(store.timelinePlaybackDurationSeconds))
                .font(.system(size: 10, design: .monospaced))

            if !store.timelinePlaybackWarnings.isEmpty {
                Label("\(store.timelinePlaybackWarnings.count)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help(store.timelinePlaybackWarnings.joined(separator: "\n"))
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(Color(nsColor: .controlBackgroundColor))
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
                    }
                }

                if let clip = store.selectedTimelineClip {
                    inspectorSection("TIMELINE CLIP") {
                        metadataRow("Start", formatTime(clip.timelineStartSeconds))
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
        }
        .font(.caption)
    }

    private func formatTime(_ seconds: Double) -> String {
        let safeSeconds = max(0, seconds.isFinite ? seconds : 0)
        let minutes = Int(safeSeconds) / 60
        let remaining = safeSeconds - Double(minutes * 60)
        return String(format: "%02d:%05.2f", minutes, remaining)
    }
}

private struct EditorTimelineView: View {
    @EnvironmentObject private var store: EditorStore

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if store.project.timelineClips.isEmpty {
                ContentUnavailableView {
                    Label("Timeline is empty", systemImage: "timeline.selection")
                } description: {
                    Text("Select a video and choose Add to Timeline.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    trackHeaders
                    Divider()
                    ScrollView(.horizontal) {
                        VStack(alignment: .leading, spacing: 5) {
                            trackRow(video: true)
                            trackRow(video: false)
                        }
                        .padding(10)
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text("TIMELINE")
                .font(.caption.weight(.bold))
                .tracking(1.1)
                .foregroundStyle(.secondary)
            Text(formatTime(store.timelineDurationSeconds))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            Button { store.moveSelectedTimelineClip(by: -1) } label: {
                Image(systemName: "arrow.left")
            }
            Button { store.moveSelectedTimelineClip(by: 1) } label: {
                Image(systemName: "arrow.right")
            }
            Button { store.toggleVideoPlayback() } label: {
                Image(systemName: store.isVideoPlaying ? "pause.fill" : "play.fill")
            }
            Button(role: .destructive) { store.removeSelectedTimelineClip() } label: {
                Image(systemName: "trash")
            }
            .disabled(store.selectedTimelineClip == nil)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    private var trackHeaders: some View {
        VStack(spacing: 5) {
            trackHeader("V1", symbol: "film")
            trackHeader("A1", symbol: "waveform")
        }
        .padding(10)
        .frame(width: 64)
    }

    private func trackHeader(_ name: String, symbol: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
            Text(name)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 56)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }

    private func trackRow(video: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(store.project.timelineClips) { clip in
                Button {
                    store.selectTimelineClip(clip)
                } label: {
                    timelineClip(clip, video: video)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(minHeight: 56)
    }

    private func timelineClip(_ clip: TimelineClip, video: Bool) -> some View {
        let selected = store.selectedTimelineClipID == clip.id
        let width = max(100, min(360, clip.durationSeconds * 18))
        let asset = store.timelineAsset(for: clip)

        return HStack(spacing: 7) {
            Image(systemName: video ? "film" : (clip.isMuted ? "speaker.slash.fill" : "waveform"))
            VStack(alignment: .leading, spacing: 2) {
                Text(asset?.filename ?? "Missing Media")
                    .lineLimit(1)
                Text(formatTime(clip.durationSeconds))
                    .font(.system(size: 9, design: .monospaced))
                    .opacity(0.76)
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .frame(width: width, alignment: .leading)
        .frame(minHeight: 56)
        .background(
            video ? Color.orange.opacity(0.72) : Color.blue.opacity(clip.isMuted ? 0.26 : 0.58),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(selected ? Color.white : Color.clear, lineWidth: 2)
        }
        .opacity(clip.isEnabled ? 1 : 0.45)
    }

    private func formatTime(_ seconds: Double) -> String {
        let safeSeconds = max(0, seconds.isFinite ? seconds : 0)
        let minutes = Int(safeSeconds) / 60
        let remaining = safeSeconds - Double(minutes * 60)
        return String(format: "%02d:%05.2f", minutes, remaining)
    }
}
