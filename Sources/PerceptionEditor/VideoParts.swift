import AVKit
import SwiftUI

/// Media bin: the project's video assets as large cards. Shared by the video screens.
struct VideoMediaBin: View {
    @EnvironmentObject private var store: EditorStore

    var body: some View {
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
                            ProxyBadge(proxyStore: store.proxyStore, assetID: asset.id)
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

    private func formatTime(_ seconds: Double) -> String {
        let safeSeconds = max(0, seconds.isFinite ? seconds : 0)
        let minutes = Int(safeSeconds) / 60
        let remaining = safeSeconds - Double(minutes * 60)
        return String(format: "%02d:%05.2f", minutes, remaining)
    }
}

/// Viewer with transport and an optional scope panel under it. Shared by the video screens.
struct VideoViewer: View {
    @EnvironmentObject private var store: EditorStore

    /// The Color screen hosts its own scope strip and passes false.
    var showsScopePanel = true

    var body: some View {
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
                if showsScopePanel {
                    Toggle(isOn: $store.scopesVisible) {
                        Label("Scopes", systemImage: "waveform.path.ecg.rectangle")
                    }
                    .toggleStyle(.button)
                    .help("Waveform and vectorscope of the picture in the viewer")
                }
                if !store.isTimelinePlayback, !store.project.timelineClips.isEmpty {
                    Button("Preview Timeline", systemImage: "play.rectangle.on.rectangle") {
                        store.previewTimeline()
                    }
                }
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
                    EditorPlayerView(player: player, showsControls: !store.isTimelinePlayback)
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

            if showsScopePanel, store.scopesVisible {
                Divider()
                ScopePanel(model: store.scopeModel)
                    .frame(height: 200)
            }

            if store.isTimelinePlayback {
                timelineTransport
            }
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

    private func formatTime(_ seconds: Double) -> String {
        let safeSeconds = max(0, seconds.isFinite ? seconds : 0)
        let minutes = Int(safeSeconds) / 60
        let remaining = safeSeconds - Double(minutes * 60)
        return String(format: "%02d:%05.2f", minutes, remaining)
    }
}

/// The timeline: toolbar, track headers and clips. Shared by the video screens.
struct VideoTimeline: View {
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
                        ZStack(alignment: .topLeading) {
                            VStack(alignment: .leading, spacing: 5) {
                                trackRow(video: true)
                                trackRow(video: false)
                            }

                            if store.isTimelinePlayback {
                                timelinePlayhead
                                    .offset(x: timelinePlayheadOffset)
                                    .accessibilityHidden(true)
                            }
                        }
                        .frame(width: timelineContentWidth, alignment: .leading)
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
            .disabled(!store.canMoveSelectedTimelineClip(by: -1))
            .help("Move selected clip earlier")
            .accessibilityLabel("Move selected clip earlier")
            Button { store.moveSelectedTimelineClip(by: 1) } label: {
                Image(systemName: "arrow.right")
            }
            .disabled(!store.canMoveSelectedTimelineClip(by: 1))
            .help("Move selected clip later")
            .accessibilityLabel("Move selected clip later")
            Toggle(isOn: $store.usesProxiesForPlayback) {
                Label("Proxies", systemImage: "bolt")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help(store.timelineUsedProxyCount > 0
                  ? "Playing \(store.timelineUsedProxyCount) clip(s) from proxies. Proxies are used only for playback; sound always comes from the originals."
                  : "Play from proxies when they are ready. Proxies are used only for playback; sound always comes from the originals.")
            Button { store.toggleVideoPlayback() } label: {
                Image(systemName: store.isVideoPlaying ? "pause.fill" : "play.fill")
            }
            .help(store.isVideoPlaying ? "Pause timeline" : "Play timeline")
            Button(role: .destructive) { store.removeSelectedTimelineClip() } label: {
                Image(systemName: "trash")
            }
            .disabled(store.selectedTimelineClip == nil)
            .help("Ripple delete selected clip")
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
        let width = timelineClipWidth(clip)
        let asset = store.timelineAsset(for: clip)

        return ZStack(alignment: .leading) {
            if !video {
                AudioWaveformView(samples: waveformSamples(for: clip))
                    .padding(.vertical, 5)
                    .opacity(clip.isMuted ? 0.18 : 0.48)
                    .accessibilityHidden(true)
            }

            HStack(spacing: 7) {
                Image(systemName: video ? "film" : (clip.isMuted ? "speaker.slash.fill" : "waveform"))
                VStack(alignment: .leading, spacing: 2) {
                    Text(asset?.filename ?? "Missing Media")
                        .lineLimit(1)
                    Text(formatTime(clip.durationSeconds))
                        .font(.system(size: 9, design: .monospaced))
                        .opacity(0.76)
                }
            }
            .padding(.horizontal, 9)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
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

    private func waveformSamples(for clip: TimelineClip) -> [Float] {
        let samples = store.audioWaveform(for: clip)
        guard !samples.isEmpty,
              let duration = store.timelineAsset(for: clip)?.durationSeconds,
              duration > 0
        else { return samples }

        let startFraction = min(1, max(0, clip.sourceStartSeconds / duration))
        let endFraction = min(1, max(startFraction, (clip.sourceStartSeconds + clip.durationSeconds) / duration))
        let start = min(samples.count - 1, Int(startFraction * Double(samples.count)))
        let end = min(samples.count, max(start + 1, Int(ceil(endFraction * Double(samples.count)))))
        return Array(samples[start..<end])
    }

    private var timelinePlayhead: some View {
        VStack(spacing: 0) {
            Image(systemName: "triangle.fill")
                .font(.system(size: 7))
                .rotationEffect(.degrees(180))
            Rectangle()
                .frame(width: 2, height: 110)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.85), radius: 1)
    }

    private var timelineContentWidth: CGFloat {
        let clips = store.project.timelineClips
        let gaps = CGFloat(max(0, clips.count - 1)) * 4
        return max(1, clips.reduce(CGFloat.zero) { $0 + timelineClipWidth($1) } + gaps)
    }

    private var timelinePlayheadOffset: CGFloat {
        let position = min(max(0, store.timelinePlaybackPositionSeconds), store.timelineDurationSeconds)
        var cursor = CGFloat.zero

        for clip in store.project.timelineClips {
            let width = timelineClipWidth(clip)
            let clipStart = store.project.timelineStartSeconds(of: clip)
            let clipEnd = clipStart + clip.durationSeconds
            if position <= clipEnd {
                let elapsed = max(0, position - clipStart)
                let fraction = clip.durationSeconds > 0 ? min(1, elapsed / clip.durationSeconds) : 0
                return cursor + width * CGFloat(fraction)
            }
            cursor += width + 4
        }

        return max(0, timelineContentWidth - 2)
    }

    private func timelineClipWidth(_ clip: TimelineClip) -> CGFloat {
        max(100, min(360, clip.durationSeconds * 18))
    }

    private func formatTime(_ seconds: Double) -> String {
        let safeSeconds = max(0, seconds.isFinite ? seconds : 0)
        let minutes = Int(safeSeconds) / 60
        let remaining = safeSeconds - Double(minutes * 60)
        return String(format: "%02d:%05.2f", minutes, remaining)
    }
}

private struct EditorPlayerView: NSViewRepresentable {
    let player: AVPlayer
    let showsControls: Bool

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.player = player
        playerView.videoGravity = .resizeAspect
        playerView.controlsStyle = showsControls ? .floating : .none
        return playerView
    }

    func updateNSView(_ playerView: AVPlayerView, context: Context) {
        playerView.player = player
        playerView.controlsStyle = showsControls ? .floating : .none
    }
}

private struct AudioWaveformView: View {
    let samples: [Float]

    var body: some View {
        Canvas { context, size in
            guard !samples.isEmpty, size.width > 0, size.height > 0 else { return }
            let centerY = size.height / 2
            let step = size.width / CGFloat(samples.count)

            for (index, sample) in samples.enumerated() {
                let height = max(1, size.height * CGFloat(min(1, max(0, sample))))
                let x = min(size.width, (CGFloat(index) + 0.5) * step)
                var path = Path()
                path.move(to: CGPoint(x: x, y: centerY - height / 2))
                path.addLine(to: CGPoint(x: x, y: centerY + height / 2))
                context.stroke(path, with: .color(.white.opacity(0.82)), lineWidth: max(1, step * 0.54))
            }
        }
    }
}

/// Observes ProxyStore directly because EditorStore does not republish progress ticks.
private struct ProxyBadge: View {
    @ObservedObject var proxyStore: ProxyStore
    let assetID: UUID

    var body: some View {
        switch proxyStore.statuses[assetID] {
        case .ready?:
            label("PROXY", systemImage: "bolt.fill", tint: .green)
        case .generating(let fraction)?:
            label("\(Int(fraction * 100))%", systemImage: "gearshape.2", tint: .orange)
        case .queued?:
            label("QUEUED", systemImage: "clock", tint: .secondary)
        case .failed(let reason)?:
            label("NO PROXY", systemImage: "exclamationmark.triangle.fill", tint: .red).help(reason)
        case .missing?, nil:
            EmptyView()
        }
    }

    private func label(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(.black.opacity(0.72), in: Capsule())
            .foregroundStyle(tint)
    }
}

