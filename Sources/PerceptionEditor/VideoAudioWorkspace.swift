import SwiftUI

/// The Video Audio screen: the viewer with transport and the timeline's audio lane (waveforms with
/// clipped spots in red) on the left; live L/R meters with a clip light, master gain, the clipped-spot
/// count with a jump button, and the selected clip's gain and fades on the right.
struct VideoAudioWorkspace: View {
    @EnvironmentObject private var store: EditorStore

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                VideoViewer(showsScopePanel: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                AudioLane()
                    .frame(height: 150)
            }
            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)

            Group {
                switch store.audioEmptyReason {
                case .noClips?, .offline?:
                    AudioEmptyState()
                case .noAudio?, nil:
                    AudioMixPanel()
                }
            }
            .frame(minWidth: 320, idealWidth: 360, maxWidth: 420, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }
}

// MARK: - Right panel

private struct AudioMixPanel: View {
    @EnvironmentObject private var store: EditorStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                section("LEVELS") {
                    AudioMeters(model: store.audioMeterModel)
                }
                section("MASTER") {
                    gainControl(
                        "Master gain",
                        value: store.project.masterGainDecibels,
                        set: { store.setMasterGainDecibels($0) },
                        reset: { store.setMasterGainDecibels(0) }
                    )
                    peakRow
                }
                section("CLIPPING") {
                    ClippingSummary()
                }
                section("CLIP") {
                    ClipAudioControls()
                }
            }
            .padding(16)
        }
    }

    private var peakRow: some View {
        HStack {
            Text("Timeline peak")
                .foregroundStyle(.secondary)
            Spacer()
            if store.isAnalyzingAudio {
                ProgressView().controlSize(.small)
            }
            Text(peakText)
                .font(.system(.callout, design: .monospaced).weight(.semibold))
                .foregroundStyle((store.audioLevels?.clippedRanges.isEmpty == false) ? Color.red : Color.primary)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
        .help("The loudest sample on the timeline after clip and master gain, as it will be exported.")
    }

    private var peakText: String {
        guard let levels = store.audioLevels else { return store.isAnalyzingAudio ? "Measuring…" : "—" }
        guard levels.peakDecibels > AudioLevelAnalyzer.floorDecibels else { return "Silent" }
        return String(format: "%+.1f dBFS", levels.peakDecibels)
    }
}

/// The selected clip's gain and fades (moved here from the Cut inspector).
private struct ClipAudioControls: View {
    @EnvironmentObject private var store: EditorStore

    var body: some View {
        if let clip = store.selectedTimelineClip {
            let name = store.timelineAsset(for: clip)?.filename ?? "Missing media"
            HStack {
                Text(name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if clip.isMuted {
                    Label("Muted", systemImage: "speaker.slash.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Reset", systemImage: "arrow.counterclockwise") {
                    store.resetSelectedAudioAdjustments()
                }
                .help("Clip gain 0 dB, no fades")
            }
            gainControl(
                "Clip gain",
                value: store.selectedAudioAdjustments.gainDecibels,
                set: { value in store.updateSelectedAudioAdjustments { $0.gainDecibels = value } },
                reset: { store.updateSelectedAudioAdjustments { $0.gainDecibels = 0 } }
            )
            fadeControl("Fade in", keyPath: \.fadeInSeconds, clip: clip)
            fadeControl("Fade out", keyPath: \.fadeOutSeconds, clip: clip)
        } else {
            Text("Select a clip in the audio lane to set its gain and fades.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func fadeControl(_ label: String, keyPath: WritableKeyPath<ClipAudioAdjustments, Double>, clip: TimelineClip) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: "%.1f s", store.selectedAudioAdjustments[keyPath: keyPath]))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            Slider(
                value: Binding(
                    get: { store.selectedAudioAdjustments[keyPath: keyPath] },
                    set: { value in store.updateSelectedAudioAdjustments { $0[keyPath: keyPath] = value } }
                ),
                in: 0 ... max(0.01, clip.durationSeconds / 2)
            )
            .controlSize(.large)
            .accessibilityLabel(label)
            .accessibilityValue(String(format: "%.1f seconds", store.selectedAudioAdjustments[keyPath: keyPath]))
        }
    }
}

/// Clipped-spot count, jump button, Show clipping toggle, and the export warning.
private struct ClippingSummary: View {
    @EnvironmentObject private var store: EditorStore

    private var count: Int { store.audioLevels?.clippedRanges.count ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: count > 0 ? "exclamationmark.octagon.fill" : "checkmark.circle.fill")
                    .foregroundStyle(count > 0 ? Color.red : Color.green)
                    .imageScale(.large)
                Text(summary)
                    .font(.callout.weight(.semibold))
                Spacer()
            }
            .accessibilityElement(children: .combine)

            if store.audioEmptyReason == .noAudio {
                Text("None of the timeline's clips has a readable audio track.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let counts = store.audioAnalysisCounts, counts.withoutAudio > 0 {
                Text("\(counts.withoutAudio) clip\(counts.withoutAudio == 1 ? "" : "s") without readable audio not measured.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if count > 0 {
                Text("The export will clip at \(count == 1 ? "this spot" : "these spots") with the current gains. Lower the clip or master gain to clear \(count == 1 ? "it" : "them").")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                store.jumpToNextClippedSpot()
            } label: {
                Label("Jump to next clipped spot", systemImage: "arrow.right.to.line")
                    .frame(maxWidth: .infinity, minHeight: EditorMetrics.categoryButtonHeight - 8)
            }
            .controlSize(.large)
            .disabled(count == 0)

            Toggle("Show clipping on the waveforms", isOn: $store.showsClipping)
                .toggleStyle(.switch)
                .font(.callout)
        }
    }

    private var summary: String {
        if store.isAnalyzingAudio, store.audioLevels == nil { return "Measuring clipping…" }
        if store.audioLevels == nil, store.audioAnalysisCounts == nil { return "Not measured yet" }
        switch count {
        case 0: return "No clipping"
        case 1: return "1 clipped spot"
        default: return "\(count) clipped spots"
        }
    }
}

/// Shown instead of the mix controls with no clips or only offline media.
private struct AudioEmptyState: View {
    @EnvironmentObject private var store: EditorStore

    var body: some View {
        ContentUnavailableView {
            Label(
                store.audioEmptyReason == .offline ? "Clip media is offline" : "No audio to mix",
                systemImage: store.audioEmptyReason == .offline ? "exclamationmark.triangle" : "waveform"
            )
        } description: {
            Text(store.audioEmptyReason == .offline
                 ? "The timeline's files cannot be found. Relink them on the Cut screen."
                 : "Add clips to the timeline on the Cut screen, then set their levels here.")
        } actions: {
            Button("Go to Cut") {
                if let cut = EditorCategory.video.steps.first(where: { $0.workspace == .video }) {
                    store.requestStepChange(cut)
                }
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Meters

/// Vertical L/R peak meters (-60…0 dBFS) with a hold line and a clip light that latches until clicked
/// or until playback starts again.
private struct AudioMeters: View {
    @ObservedObject var model: AudioMeterModel

    var body: some View {
        HStack(alignment: .bottom, spacing: 14) {
            scale
            meter("L", level: model.state.levelDecibels.left, hold: model.state.holdDecibels.left, name: "Left")
            meter("R", level: model.state.levelDecibels.right, hold: model.state.holdDecibels.right, name: "Right")
            Spacer()
            clipLight
        }
        .frame(height: 170)
    }

    private var scale: some View {
        GeometryReader { geometry in
            ForEach([0, -6, -12, -24, -48], id: \.self) { mark in
                Text("\(mark)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .position(x: 12, y: (geometry.size.height - 18) * (1 - AudioMeterState.fraction(forDecibels: Double(mark))))
            }
        }
        .frame(width: 24)
        .accessibilityHidden(true)
    }

    private func meter(_ label: String, level: Double, hold: Double, name: String) -> some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                let height = geometry.size.height
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(nsColor: .quaternaryLabelColor))
                    LinearGradient(
                        stops: [
                            .init(color: .green, location: 0),
                            .init(color: .green, location: AudioMeterState.fraction(forDecibels: -12)),
                            .init(color: .yellow, location: AudioMeterState.fraction(forDecibels: -6)),
                            .init(color: .red, location: 1)
                        ],
                        startPoint: .bottom, endPoint: .top
                    )
                    .mask(alignment: .bottom) {
                        Rectangle().frame(height: height * AudioMeterState.fraction(forDecibels: level))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    if hold > AudioMeterState.floorDecibels {
                        Rectangle()
                            .fill(Color.primary)
                            .frame(height: 2)
                            .offset(y: -height * AudioMeterState.fraction(forDecibels: hold) + 1)
                    }
                }
            }
            .frame(width: 22)
            Text(label)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) channel level")
        .accessibilityValue(level <= AudioMeterState.floorDecibels ? "Silent" : String(format: "%.0f decibels full scale, peak %.0f", level, hold))
    }

    private var clipLight: some View {
        Button {
            model.clearClip()
        } label: {
            VStack(spacing: 6) {
                Circle()
                    .fill(model.state.clipped ? Color.red : Color(nsColor: .quaternaryLabelColor))
                    .frame(width: 28, height: 28)
                    .overlay(Circle().stroke(Color.secondary.opacity(0.5), lineWidth: 1))
                    .shadow(color: model.state.clipped ? .red.opacity(0.7) : .clear, radius: 6)
                Text("CLIP")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(model.state.clipped ? Color.red : Color.secondary)
            }
            .frame(minWidth: 56, minHeight: EditorMetrics.railButtonHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Lights when playback reaches full scale after gain. Click to clear; it also clears when playback starts again.")
        .accessibilityLabel("Clip indicator")
        .accessibilityValue(model.state.clipped ? "Clipped. Click to clear." : "Not clipped")
    }
}

// MARK: - Gain control

/// A dB slider (−60…+24, "Off" at the floor) with a large readout and a 0 dB reset.
@MainActor
private func gainControl(
    _ label: String,
    value: Double,
    set: @escaping (Double) -> Void,
    reset: @escaping () -> Void
) -> some View {
    VStack(spacing: 4) {
        HStack {
            Text(label)
            Spacer()
            Text(value <= ClipAudioAdjustments.minimumGainDecibels ? "Off" : String(format: "%+.1f dB", value))
                .font(.system(.callout, design: .monospaced).weight(.semibold))
            Button {
                reset()
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .disabled(value == 0)
            .help("Back to 0 dB")
            .accessibilityLabel("Reset \(label.lowercased()) to 0 dB")
        }
        .font(.callout)
        Slider(value: Binding(get: { value }, set: set), in: ClipAudioAdjustments.gainRange)
            .controlSize(.large)
            .accessibilityLabel(label)
            .accessibilityValue(value <= ClipAudioAdjustments.minimumGainDecibels ? "Off" : String(format: "%+.1f decibels", value))
    }
}

private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 10) {
        Text(title)
            .font(.caption.weight(.bold))
            .tracking(1.1)
            .foregroundStyle(.secondary)
        content()
    }
}

// MARK: - Audio lane

/// The timeline's audio track at the width of the panel: one block per clip with its waveform,
/// clipped spots in red (timeline time, from `audioLevels`), and the playhead. Clicking a clip
/// selects it.
private struct AudioLane: View {
    @EnvironmentObject private var store: EditorStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("AUDIO")
                    .font(.caption.weight(.bold))
                    .tracking(1.1)
                    .foregroundStyle(.secondary)
                Text(formatTime(store.timelineDurationSeconds))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                if store.isAnalyzingAudio {
                    ProgressView().controlSize(.small)
                    Text("Measuring…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            Divider()

            if store.project.timelineClips.isEmpty {
                ContentUnavailableView("Timeline is empty", systemImage: "waveform")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    lane(width: geometry.size.width, height: geometry.size.height)
                }
                .padding(10)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func lane(width: CGFloat, height: CGFloat) -> some View {
        let duration = max(0.001, store.timelineDurationSeconds)
        let scale = width / CGFloat(duration)
        let spots = store.showsClipping ? (store.audioLevels?.clippedRanges ?? []) : []
        return ZStack(alignment: .topLeading) {
            ForEach(store.project.timelineClips) { clip in
                let start = store.project.timelineStartSeconds(of: clip)
                let length = store.project.sequenceFrameRate.seconds(ofFrames: store.project.timelineFrames(of: clip))
                Button {
                    store.selectTimelineClip(clip)
                } label: {
                    clipBlock(clip, start: start, length: length, scale: scale, height: height, spots: spots)
                }
                .buttonStyle(.plain)
                .offset(x: CGFloat(start) * scale)
                .accessibilityLabel("Audio of \(store.timelineAsset(for: clip)?.filename ?? "missing media")")
            }
            if store.isTimelinePlayback {
                Rectangle()
                    .fill(Color.primary)
                    .frame(width: 2, height: height)
                    .offset(x: min(width - 2, CGFloat(store.timelinePlaybackPositionSeconds) * scale))
                    .accessibilityHidden(true)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }

    private func clipBlock(
        _ clip: TimelineClip, start: Double, length: Double, scale: CGFloat, height: CGFloat, spots: [ClosedRange<Double>]
    ) -> some View {
        let blockWidth = max(3, CGFloat(length) * scale - 2)
        let selected = store.selectedTimelineClipID == clip.id
        let mine = spots.filter { $0.upperBound >= start && $0.lowerBound <= start + length }
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(clip.isMuted ? 0.12 : 0.28))
            AudioWaveformView(samples: store.clipWaveformSamples(for: clip), color: .primary.opacity(clip.isMuted ? 0.25 : 0.7))
                .padding(.vertical, 6)
                .accessibilityHidden(true)
            ForEach(Array(mine.enumerated()), id: \.offset) { _, spot in
                let lower = max(spot.lowerBound, start) - start
                let upper = min(spot.upperBound, start + length) - start
                Rectangle()
                    .fill(Color.red.opacity(0.85))
                    .frame(width: max(2, CGFloat(upper - lower) * scale), height: height)
                    .offset(x: CGFloat(lower) * scale)
            }
            if clip.isMuted {
                Image(systemName: "speaker.slash.fill")
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
        }
        .frame(width: blockWidth, height: height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: selected ? 2 : 1)
        }
        .accessibilityValue(mine.isEmpty ? "No clipping" : "\(mine.count) clipped spot\(mine.count == 1 ? "" : "s")")
    }
}
