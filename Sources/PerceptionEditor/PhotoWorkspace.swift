import SwiftUI

struct PhotoWorkspace: View {
    @EnvironmentObject private var store: EditorStore
    @State private var isSavingPreset = false
    @State private var presetName = ""

    var body: some View {
        HSplitView {
            presetPanel
                .frame(minWidth: 185, idealWidth: 210, maxWidth: 250)
            previewPanel
                .frame(minWidth: 580, maxWidth: .infinity, maxHeight: .infinity)
            adjustmentPanel
                .frame(minWidth: 260, idealWidth: 290, maxWidth: 330)
        }
    }

    private var presetPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                panelHeading("PRESETS", symbol: "camera.filters")
                Spacer()
                Button {
                    presetName = ""
                    isSavingPreset = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Save current adjustments as a user preset")
                .disabled(store.selectedAsset == nil)
            }

            ScrollView {
                VStack(spacing: 9) {
                    ForEach(store.presets) { preset in
                        Button {
                            store.apply(preset)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(preset.name)
                                    .font(.callout.weight(.semibold))
                                Text(preset.category.uppercased())
                                    .font(.system(size: 9, weight: .bold))
                                    .tracking(0.8)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if store.isUserPreset(preset) {
                                Button("Delete Preset", role: .destructive) {
                                    store.deleteUserPreset(preset)
                                }
                            }
                        }
                    }
                }
            }

            Spacer()

            Button("Reset Adjustments", systemImage: "arrow.counterclockwise") {
                store.resetAdjustments()
            }
            .buttonStyle(.bordered)
            .disabled(store.selectedAsset == nil)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .alert("Save User Preset", isPresented: $isSavingPreset) {
            TextField("Preset name", text: $presetName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                store.saveUserPreset(named: presetName)
            }
            .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Save the selected photo's current adjustments for reuse.")
        }
    }

    private var previewPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text(store.selectedAsset?.filename ?? "No photo selected")
                    .font(.callout.weight(.semibold))
                Spacer()

                Button {
                    store.rotate(clockwise: false)
                } label: {
                    Image(systemName: "rotate.left")
                }
                .disabled(store.selectedAsset == nil)

                Button {
                    store.rotate(clockwise: true)
                } label: {
                    Image(systemName: "rotate.right")
                }
                .disabled(store.selectedAsset == nil)

                if let asset = store.selectedAsset, store.isMissing(asset) {
                    Button("Relink", systemImage: "link.badge.plus") {
                        store.relink(asset)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }

                Picker("Comparison", selection: $store.previewMode) {
                    ForEach(PreviewMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 330)
                .disabled(store.selectedAsset == nil)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(Color(nsColor: .controlBackgroundColor))

            PhotoComparisonView(
                original: store.originalPreview,
                edited: store.renderedPreview,
                mode: store.previewMode
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            filmstrip
                .frame(height: 116)
        }
    }

    private var filmstrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(store.project.media.filter { $0.kind == .photo }) { asset in
                    Button {
                        store.select(asset)
                    } label: {
                        Group {
                            if let image = store.thumbnail(for: asset) {
                                Image(nsImage: image)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                Color.gray.opacity(0.3)
                            }
                        }
                        .frame(width: 118, height: 82)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(asset.id == store.selectedAssetID ? Color.orange : .clear, lineWidth: 3)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Relink Media…") { store.relink(asset) }
                    }
                }
            }
            .padding(.horizontal, 14)
        }
        .contentMargins(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var adjustmentPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                panelHeading("ADJUSTMENTS", symbol: "slider.horizontal.3")

                adjustmentGroup("HISTOGRAM") {
                    HistogramView(data: store.histogram)
                        .frame(height: 92)
                }

                adjustmentGroup("LIGHT") {
                    adjustment("Exposure", keyPath: \.exposure, range: -3...3)
                    adjustment("Contrast", keyPath: \.contrast, range: -1...1)
                    adjustment("Highlights", keyPath: \.highlights, range: -1...1)
                    adjustment("Shadows", keyPath: \.shadows, range: -1...1)
                }

                adjustmentGroup("COLOR") {
                    adjustment("Temperature", keyPath: \.temperature, range: -1...1)
                    adjustment("Tint", keyPath: \.tint, range: -1...1)
                    adjustment("Vibrance", keyPath: \.vibrance, range: -1...1)
                    adjustment("Saturation", keyPath: \.saturation, range: -1...1)
                }

                adjustmentGroup("PRESENCE") {
                    adjustment("Sharpness", keyPath: \.sharpness, range: 0...1)
                    adjustment("Vignette", keyPath: \.vignette, range: 0...1)
                }

                adjustmentGroup("CROP") {
                    Picker("Aspect", selection: Binding(
                        get: { store.selectedAdjustments.cropAspect },
                        set: { value in store.updateAdjustments { $0.cropAspect = value } }
                    )) {
                        ForEach(CropAspect.allCases) { aspect in
                            Text(aspect.rawValue).tag(aspect)
                        }
                    }
                    .disabled(store.selectedAsset == nil)
                }
            }
            .padding(15)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func panelHeading(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.bold))
            .tracking(1.1)
            .foregroundStyle(.secondary)
    }

    private func adjustmentGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.caption2.weight(.bold))
                .tracking(1)
                .foregroundStyle(.secondary)
            content()
        }
        .padding(.bottom, 3)
    }

    private func adjustment(
        _ label: String,
        keyPath: WritableKeyPath<PhotoAdjustments, Double>,
        range: ClosedRange<Double>
    ) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption)
                Spacer()
                Text(store.selectedAdjustments[keyPath: keyPath], format: .number.precision(.fractionLength(2)))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
            Slider(
                value: Binding(
                    get: { store.selectedAdjustments[keyPath: keyPath] },
                    set: { value in store.updateAdjustments { $0[keyPath: keyPath] = value } }
                ),
                in: range
            )
            .tint(.orange)
            .disabled(store.selectedAsset == nil)
        }
    }
}
