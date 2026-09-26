import SwiftUI

struct PhotoWorkspace: View {
    @EnvironmentObject private var store: EditorStore
    @State private var isSavingPreset = false
    @State private var presetName = ""
    @State private var zoomScale: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    @State private var isCropping = false
    @State private var draftCropRect: CGRect?

    var body: some View {
        HSplitView {
            presetPanel
                .frame(minWidth: 185, idealWidth: 210, maxWidth: 250)
            previewPanel
                .frame(minWidth: 580, maxWidth: .infinity, maxHeight: .infinity)
            adjustmentPanel
                .frame(minWidth: 260, idealWidth: 290, maxWidth: 330)
        }
        .onChange(of: store.selectedAssetID) { _, _ in
            resetPreviewViewport()
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
                .help("Rotate counterclockwise")

                Button {
                    store.rotate(clockwise: true)
                } label: {
                    Image(systemName: "rotate.right")
                }
                .disabled(store.selectedAsset == nil)
                .help("Rotate clockwise")

                if isCropping {
                    Button("Apply Crop", systemImage: "checkmark") {
                        applyCrop()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)

                    Button("Cancel", systemImage: "xmark") {
                        cancelCrop()
                    }
                    .buttonStyle(.borderless)
                } else {
                    Button("Crop", systemImage: "crop") {
                        beginCrop()
                    }
                    .buttonStyle(.bordered)
                    .disabled(store.selectedAsset == nil)
                    .help("Crop and straighten the selected photo")
                }

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

                zoomControls
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(Color(nsColor: .controlBackgroundColor))

            PhotoComparisonView(
                original: store.originalPreview,
                edited: store.renderedPreview,
                mode: store.previewMode,
                zoomScale: $zoomScale,
                panOffset: $panOffset,
                isCropping: isCropping,
                cropRect: $draftCropRect,
                cropAspect: store.selectedAdjustments.cropAspect
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

                    straightenAdjustment
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
                if abs(store.selectedAdjustments[keyPath: keyPath]) > 0.0001 {
                    Button {
                        store.updateAdjustments { $0[keyPath: keyPath] = 0 }
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                    .help("Reset \(label)")
                }
                TextField(
                    label,
                    value: Binding(
                        get: { store.selectedAdjustments[keyPath: keyPath] },
                        set: { value in store.updateAdjustments { $0[keyPath: keyPath] = value } }
                    ),
                    format: .number.precision(.fractionLength(2))
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 58)
            }
            Slider(
                value: Binding(
                    get: { store.selectedAdjustments[keyPath: keyPath] },
                    set: { value in store.updateAdjustments { $0[keyPath: keyPath] = value } }
                ),
                in: range,
                onEditingChanged: { editing in
                    if editing {
                        store.beginAdjustmentEdit()
                    } else {
                        store.endAdjustmentEdit()
                    }
                }
            )
            .tint(.orange)
            .disabled(store.selectedAsset == nil)
        }
    }

    private var straightenAdjustment: some View {
        let value = store.selectedAdjustments.straightenDegrees ?? 0
        return VStack(spacing: 4) {
            HStack {
                Text("Straighten")
                    .font(.caption)
                Spacer()
                if abs(value) > 0.0001 {
                    Button {
                        store.updateAdjustments { $0.straightenDegrees = nil }
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                    .help("Reset Straighten")
                }
                TextField(
                    "Straighten",
                    value: Binding(
                        get: { store.selectedAdjustments.straightenDegrees ?? 0 },
                        set: { newValue in store.updateAdjustments { $0.straightenDegrees = newValue } }
                    ),
                    format: .number.precision(.fractionLength(1))
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 58)
            }
            Slider(
                value: Binding(
                    get: { store.selectedAdjustments.straightenDegrees ?? 0 },
                    set: { newValue in store.updateAdjustments { $0.straightenDegrees = newValue } }
                ),
                in: -10...10,
                onEditingChanged: { editing in
                    if editing {
                        store.beginAdjustmentEdit()
                    } else {
                        store.endAdjustmentEdit()
                    }
                }
            )
            .tint(.orange)
            .disabled(store.selectedAsset == nil)
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button {
                zoomScale = max(0.5, zoomScale - 0.25)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Zoom out")
            .disabled(store.selectedAsset == nil)

            Menu {
                ForEach([0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 4.0], id: \.self) { value in
                    Button("\(Int(value * 100))%") {
                        zoomScale = value
                    }
                }
            } label: {
                Text("\(Int(zoomScale * 100))%")
                    .font(.system(size: 10, design: .monospaced))
                    .frame(width: 42)
            }
            .menuStyle(.borderlessButton)
            .help("Preview zoom")

            Button {
                zoomScale = min(4, zoomScale + 0.25)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Zoom in")
            .disabled(store.selectedAsset == nil)

            Button {
                resetPreviewViewport()
            } label: {
                Image(systemName: "arrow.up.left.and.down.right.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Reset zoom and pan")
        }
    }

    private func beginCrop() {
        guard store.selectedAsset != nil else { return }
        store.previewMode = .edited
        store.beginAdjustmentEdit()
        let stored = store.selectedAdjustments.cropRect
        draftCropRect = stored.map {
            CGRect(x: $0.x, y: 1 - $0.y - $0.height, width: $0.width, height: $0.height)
        }
        isCropping = true
    }

    private func applyCrop() {
        store.updateCropRectFromDisplay(draftCropRect)
        store.endAdjustmentEdit()
        draftCropRect = nil
        isCropping = false
    }

    private func cancelCrop() {
        store.cancelAdjustmentEdit()
        draftCropRect = nil
        isCropping = false
    }

    private func resetPreviewViewport() {
        zoomScale = 1
        panOffset = .zero
        draftCropRect = nil
        isCropping = false
    }
}
