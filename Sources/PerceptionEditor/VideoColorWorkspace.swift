import SwiftUI

/// The Video Color screen: the viewer with before/after, a scope strip under it, and the grade
/// for the selected timeline clip on the right. The store decides when the scopes run.
struct VideoColorWorkspace: View {
    @EnvironmentObject private var store: EditorStore

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                ColorViewerBar()
                Divider()
                VideoViewer(showsScopePanel: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                if store.colorHasTarget {
                    ColorScopeStrip(model: store.scopeModel)
                        .frame(height: 230)
                }
            }
            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)

            Group {
                if store.colorHasTarget {
                    ColorGradePanel()
                        .environment(\.adjustmentEditing, store.videoAdjustmentEditing)
                } else {
                    ColorEmptyState()
                }
            }
            .frame(minWidth: 300, idealWidth: 340, maxWidth: 400, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }
}

/// Clip name, previous and next clip, and the before/after toggle.
private struct ColorViewerBar: View {
    @EnvironmentObject private var store: EditorStore

    private var clipIndex: Int? {
        guard let id = store.selectedTimelineClipID else { return nil }
        return store.project.timelineClips.firstIndex { $0.id == id }
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                step(by: -1)
            } label: {
                Image(systemName: "chevron.left").frame(width: 28, height: 24)
            }
            .disabled((clipIndex ?? 0) <= 0)
            .help("Previous clip")
            .accessibilityLabel("Previous clip")

            Text(clipTitle)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            Button {
                step(by: 1)
            } label: {
                Image(systemName: "chevron.right").frame(width: 28, height: 24)
            }
            .disabled(clipIndex.map { $0 >= store.project.timelineClips.count - 1 } ?? true)
            .help("Next clip")
            .accessibilityLabel("Next clip")

            Spacer()

            Toggle(isOn: $store.videoBeforeAfter) {
                Label("Before / after", systemImage: "rectangle.lefthalf.inset.filled")
                    .frame(minHeight: 24)
            }
            .toggleStyle(.button)
            .disabled(!store.colorHasTarget)
            .help("Show every clip on the timeline as recorded: ungraded, with no source color. Export is not affected.")
        }
        .controlSize(.large)
        .padding(.horizontal, 16)
        .frame(minHeight: EditorMetrics.categoryButtonHeight + 12)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var clipTitle: String {
        guard let index = clipIndex else { return "No clip selected" }
        let clip = store.project.timelineClips[index]
        let name = store.timelineAsset(for: clip)?.filename ?? "Missing media"
        return "Clip \(index + 1) of \(store.project.timelineClips.count) · \(name)"
    }

    private func step(by offset: Int) {
        guard let index = clipIndex else { return }
        let clips = store.project.timelineClips
        let target = index + offset
        guard clips.indices.contains(target) else { return }
        store.selectTimelineClip(clips[target])
    }
}

/// Waveform, histogram and vectorscope side by side, with chips that pick the waveform mode and
/// show or hide the histogram and vectorscope panes.
private struct ColorScopeStrip: View {
    @EnvironmentObject private var store: EditorStore
    @ObservedObject var model: ScopeModel

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                chip("Waveform", isOn: model.waveformMode == .luma) { store.setWaveformMode(.luma) }
                chip("RGB parade", isOn: model.waveformMode == .rgbParade) { store.setWaveformMode(.rgbParade) }
                Divider().frame(height: 22)
                chip("Histogram", isOn: store.colorScopeShowsHistogram) { store.colorScopeShowsHistogram.toggle() }
                chip("Vectorscope", isOn: store.colorScopeShowsVectorscope) { store.colorScopeShowsVectorscope.toggle() }

                Spacer()

                Picker("Measure", selection: $store.scopeSource) {
                    ForEach(ScopeTap.Source.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
                .help("Output measures the graded picture. Source measures the decoded code values as recorded, before the input LUT and grade.")

                Text(String(format: "%.0f Hz", model.updatesPerSecond))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .help(String(format: "%.2f ms GPU per analysis", model.gpuMilliseconds))
            }

            HStack(spacing: 8) {
                pane(model.waveformMode == .luma ? "WAVEFORM" : "RGB PARADE") {
                    ScopeImageView(image: model.waveform)
                }
                .frame(maxWidth: .infinity)
                if store.colorScopeShowsHistogram {
                    pane("HISTOGRAM") {
                        HistogramView(data: model.histogram)
                    }
                    .frame(maxWidth: .infinity)
                }
                if store.colorScopeShowsVectorscope {
                    pane("VECTORSCOPE") {
                        ScopeImageView(image: model.vectorscope)
                            .aspectRatio(1, contentMode: .fit)
                    }
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func chip(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(isOn ? .semibold : .regular))
                .padding(.horizontal, 12)
                .frame(minHeight: EditorMetrics.categoryButtonHeight - 8)
                .background(
                    isOn ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.10),
                    in: Capsule()
                )
                .overlay(Capsule().stroke(isOn ? Color.accentColor : Color.secondary.opacity(0.25)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func pane<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.bold))
                .tracking(1)
                .foregroundStyle(.secondary)
            content()
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

/// Source color, curves, light and color sliders, and HSL for the selected clip.
private struct ColorGradePanel: View {
    @EnvironmentObject private var store: EditorStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label("GRADE", systemImage: "camera.filters")
                        .font(.caption.weight(.bold))
                        .tracking(1.1)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset", systemImage: "arrow.counterclockwise") {
                        store.resetSelectedVideoAdjustments()
                    }
                    .help("Reset this clip's grade")
                }

                if let clip = store.selectedTimelineClip, let asset = store.timelineAsset(for: clip) {
                    section("SOURCE COLOR") {
                        SourceColorPicker(asset: asset)
                    }
                }

                section("CURVES") {
                    ToneCurveEditor()
                }

                section("LIGHT") {
                    VideoAdjustmentSlider(label: "Exposure", keyPath: \.exposure, range: -3...3)
                    VideoAdjustmentSlider(label: "Contrast", keyPath: \.contrast, range: -1...1)
                    VideoAdjustmentSlider(label: "Highlights", keyPath: \.highlights, range: -1...1)
                    VideoAdjustmentSlider(label: "Shadows", keyPath: \.shadows, range: -1...1)
                }

                section("COLOR") {
                    VideoAdjustmentSlider(label: "Temperature", keyPath: \.temperature, range: -1...1)
                    VideoAdjustmentSlider(label: "Tint", keyPath: \.tint, range: -1...1)
                    VideoAdjustmentSlider(label: "Vibrance", keyPath: \.vibrance, range: -1...1)
                    VideoAdjustmentSlider(label: "Saturation", keyPath: \.saturation, range: -1...1)
                }

                section("HSL") {
                    HSLPanel()
                }

                section("DETAIL") {
                    VideoAdjustmentSlider(label: "Sharpness", keyPath: \.sharpness, range: 0...1)
                    VideoAdjustmentSlider(label: "Vignette", keyPath: \.vignette, range: 0...1)
                }

                section("LOOK LUT") {
                    LUTControls(
                        application: store.selectedVideoAdjustments.lut,
                        setLUT: { store.setClipLUT($0) },
                        setIntensity: { value in store.updateSelectedVideoAdjustments { $0.lut?.intensity = value } }
                    )
                }

                if !store.timelinePlaybackWarnings.isEmpty {
                    section("PLAYBACK WARNINGS") {
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
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.caption2.weight(.bold))
                .tracking(1)
                .foregroundStyle(.secondary)
            content()
        }
    }
}

/// Shown instead of the grade controls when no timeline clip is selected.
private struct ColorEmptyState: View {
    @EnvironmentObject private var store: EditorStore

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: reason == .offline ? "exclamationmark.triangle" : "camera.filters")
        } description: {
            Text(message)
        } actions: {
            if reason == .noSelection, let first = store.project.timelineClips.first {
                Button("Grade the First Clip") { store.selectTimelineClip(first) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            Button("Go to Cut") {
                if let cut = EditorCategory.video.steps.first(where: { $0.workspace == .video }) {
                    store.requestStepChange(cut)
                }
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var reason: EditorStore.ColorEmptyReason { store.colorEmptyReason ?? .noSelection }

    private var title: String {
        reason == .offline ? "Clip media is offline" : "No clip to grade"
    }

    private var message: String {
        switch reason {
        case .noClips: "Add clips to the timeline on the Cut screen, then grade them here."
        case .noSelection: "Select a timeline clip on the Cut screen to grade it."
        case .offline: "The selected clip's file cannot be found. Relink it, or select another clip."
        }
    }
}
