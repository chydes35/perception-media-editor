import SwiftUI

struct PhotoWorkspace: View {
    @EnvironmentObject private var store: EditorStore
    @Environment(\.displayScale) private var displayScale
    @State private var isCropping = false
    @State private var draftCropRect: CGRect?
    @State private var zoom = PhotoZoomViewport()

    var body: some View {
        HSplitView {
            PresetPanel()
                .frame(minWidth: 185, idealWidth: 210, maxWidth: 250)
            previewPanel
                .frame(minWidth: 580, maxWidth: .infinity, maxHeight: .infinity)
            adjustmentPanel
                .frame(minWidth: 260, idealWidth: 290, maxWidth: 330)
        }
        .onChange(of: store.selectedAssetID) { _, _ in
            resetPreviewViewport()
        }
        .onDisappear {
            if isCropping {
                cancelCrop()
            }
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
                .labelsHidden()
                .frame(width: 330)
                .disabled(store.selectedAsset == nil)

                zoomControls
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(Color(nsColor: .controlBackgroundColor))

            GeometryReader { geometry in
                ZStack {
                    Color.black
                    if store.isZoom100 {
                        FocusLoupeView()
                    } else {
                        PhotoComparisonView(
                            original: store.originalPreview,
                            edited: store.renderedPreview,
                            mode: store.previewMode,
                            isCropping: isCropping,
                            cropRect: $draftCropRect,
                            cropAspect: store.selectedAdjustments.cropAspect,
                            onZoomRequest: { store.enterZoom100(at: $0) }
                        )
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .scaleEffect(zoom.scale)
                        .offset(zoom.offset)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .background {
                    PhotoWheelCapture(
                        onZoom: { delta, precise, pointer, viewport in
                            zoomPhoto(by: delta, precise: precise, at: pointer, viewport: viewport)
                        },
                        onPan: { translation, viewport in
                            guard let image = zoomImageSize(in: viewport), !store.isZoom100 else { return }
                            zoom.pan(by: translation, viewport: viewport, image: image)
                        },
                        canPan: zoom.scale > 1 && !store.isZoom100
                    )
                }
                .onChange(of: geometry.size) { _, size in
                    if let image = zoomImageSize(in: size) {
                        zoom.constrain(viewport: size, image: image)
                    }
                }
                .onChange(of: store.renderedPreview?.size) { _, _ in
                    if let image = zoomImageSize(in: geometry.size) {
                        zoom.constrain(viewport: geometry.size, image: image)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            filmstrip
                .frame(height: 116)
        }
    }

    private var filmstrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(store.visiblePhotos) { asset in
                    Button {
                        let modifiers = NSEvent.modifierFlags
                        if modifiers.contains(.command) {
                            store.toggleSelection(asset)
                        } else if modifiers.contains(.shift) {
                            store.extendSelection(to: asset)
                        } else {
                            store.select(asset)
                        }
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
                                .stroke(
                                    asset.id == store.selectedAssetID ? Color.orange
                                        : (store.selectedAssetIDs.contains(asset.id) ? Color.orange.opacity(0.5) : .clear),
                                    lineWidth: 3
                                )
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
                    HStack {
                        Button {
                            if store.isAnalyzingAuto {
                                store.cancelAutoAdjustment()
                                store.statusMessage = "Auto adjustment canceled"
                            } else {
                                store.startAutoAdjustment()
                            }
                        } label: {
                            Label(store.isAnalyzingAuto ? "Cancel Auto" : "Auto", systemImage: "wand.and.stars")
                        }
                        .disabled(store.selectedAsset == nil || store.isEditingCrop)
                        .help("Suggest exposure, contrast, highlights, shadows and white balance for this photo.")
                        if store.isAnalyzingAuto { ProgressView().controlSize(.small) }
                        Spacer()
                    }
                }

                if store.selectedIsRAW {
                    adjustmentGroup("WHITE BALANCE") { whiteBalanceControls }
                }

                adjustmentGroup("LIGHT") {
                    adjustment("Exposure", keyPath: \.exposure, range: -3...3)
                    adjustment("Contrast", keyPath: \.contrast, range: -1...1)
                    adjustment("Highlights", keyPath: \.highlights, range: -1...1)
                    adjustment("Shadows", keyPath: \.shadows, range: -1...1)
                }

                adjustmentGroup("COLOR") {
                    adjustment("Warmth", keyPath: \.temperature, range: -1...1)
                    adjustment("Tint", keyPath: \.tint, range: -1...1)
                    adjustment("Vibrance", keyPath: \.vibrance, range: -1...1)
                    adjustment("Saturation", keyPath: \.saturation, range: -1...1)
                }

                adjustmentGroup("PRESENCE") {
                    adjustment("Sharpness", keyPath: \.sharpness, range: 0...1)
                    adjustment("Vignette", keyPath: \.vignette, range: 0...1)
                }

                adjustmentGroup("TONE CURVE") {
                    ToneCurveEditor()
                }

                adjustmentGroup("HSL") {
                    HSLPanel()
                }

                adjustmentGroup("MASKS") {
                    MaskPanel()
                }

                adjustmentGroup("HEAL & CLONE") {
                    RetouchPanel()
                }

                if store.selectedIsRAW {
                    adjustmentGroup("RAW DETAIL") { rawDetailControls }
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

    // MARK: - RAW controls

    private var whiteBalanceControls: some View {
        let raw = store.selectedAdjustments.raw
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Menu {
                    Button("As Shot") { store.resetWhiteBalance() }
                    Divider()
                    ForEach(WhiteBalancePreset.allCases) { preset in
                        Button("\(preset.rawValue)  \(Int(preset.temperature)) K") {
                            store.applyWhiteBalance(preset)
                        }
                    }
                } label: {
                    Text(raw.hasWhiteBalance ? "Custom" : "As Shot")
                        .font(.caption.weight(.semibold))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("White balance presets")

                Spacer()

                Button {
                    store.toggleWhiteBalancePicker()
                } label: {
                    Label(store.isPickingWhiteBalance ? "Cancel" : "Pick neutral", systemImage: "eyedropper")
                }
                .buttonStyle(.bordered)
                .tint(store.isPickingWhiteBalance ? .orange : .accentColor)
                .font(.caption)
                .disabled(store.isSamplingWhiteBalance || store.isEditingCrop)
                .help("Click a neutral gray or white area in the photo to set RAW white balance")

                if store.isSamplingWhiteBalance || store.isRenderingPreview {
                    ProgressView().controlSize(.small)
                }
                if raw.hasWhiteBalance {
                    Button {
                        store.resetWhiteBalance()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                    .help("Back to the camera's white balance")
                }
            }

            if store.isPickingWhiteBalance {
                Text("Click a neutral gray or white area in the photo. Press Esc to cancel.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 4) {
                HStack {
                    Text("Temperature").font(.caption)
                    Spacer()
                    TextField(
                        "Temperature",
                        value: Binding(
                            get: { store.displayedTemperature.rounded() },
                            set: { value in
                                store.updateAdjustments { $0.raw.temperature = min(50000, max(2000, value)) }
                            }
                        ),
                        format: .number.precision(.fractionLength(0))
                    )
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 66)
                    Text("K").font(.caption2).foregroundStyle(.secondary)
                }
                // Kelvin is perceptually logarithmic, so the slider moves in equal steps of color, not of Kelvin.
                Slider(
                    value: Binding(
                        get: { log(min(12000, max(2000, store.displayedTemperature))) },
                        set: { value in
                            store.updateAdjustments { $0.raw.temperature = exp(value).rounded() }
                        }
                    ),
                    in: log(2000.0) ... log(12000.0),
                    onEditingChanged: { editing in
                        if editing { store.beginAdjustmentEdit() } else { store.endAdjustmentEdit() }
                    }
                )
                .tint(.orange)
                .accessibilityLabel("White balance temperature")
                .accessibilityValue("\(Int(store.displayedTemperature)) Kelvin")
            }

            VStack(spacing: 4) {
                HStack {
                    Text("Tint").font(.caption)
                    Spacer()
                    TextField(
                        "Tint",
                        value: Binding(
                            get: { store.displayedTint.rounded() },
                            set: { value in
                                store.updateAdjustments { $0.raw.tint = min(150, max(-150, value)) }
                            }
                        ),
                        format: .number.precision(.fractionLength(0))
                    )
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 66)
                }
                Slider(
                    value: Binding(
                        get: { store.displayedTint },
                        set: { value in store.updateAdjustments { $0.raw.tint = value.rounded() } }
                    ),
                    in: -150 ... 150,
                    onEditingChanged: { editing in
                        if editing { store.beginAdjustmentEdit() } else { store.endAdjustmentEdit() }
                    }
                )
                .tint(.orange)
                .accessibilityLabel("White balance tint")
            }
        }
        .disabled(store.isSamplingWhiteBalance)
    }

    private var rawDetailControls: some View {
        let info = store.rawInfo
        return VStack(alignment: .leading, spacing: 12) {
            if info?.supportsNoiseReduction == true {
                rawSlider(
                    "Luminance Noise",
                    keyPath: \.luminanceNoiseReduction,
                    range: 0...1,
                    defaultValue: info?.defaultLuminanceNoiseReduction ?? 0
                )
                rawSlider(
                    "Color Noise",
                    keyPath: \.colorNoiseReduction,
                    range: 0...1,
                    defaultValue: info?.defaultColorNoiseReduction ?? 0
                )
            }
            if info?.supportsSharpness == true {
                rawSlider(
                    "Sharpness",
                    keyPath: \.sharpness,
                    range: 0...1,
                    defaultValue: info?.defaultSharpness ?? 0
                )
            }
            if info?.supportsDetail == true {
                rawSlider(
                    "Detail",
                    keyPath: \.detail,
                    range: 0...3,
                    defaultValue: info?.defaultDetail ?? 0
                )
            }
            if info?.supportsLensCorrection == true {
                Toggle(
                    "Lens corrections",
                    isOn: Binding(
                        get: { store.selectedAdjustments.raw.lensCorrection ?? info?.lensCorrectionDefault ?? true },
                        set: { value in
                            store.updateAdjustments {
                                $0.raw.lensCorrection = value == info?.lensCorrectionDefault ? nil : value
                            }
                        }
                    )
                )
                .toggleStyle(.checkbox)
                .font(.caption)
            }
            Text("These change how the RAW file is decoded, so the preview takes about half a second to update.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// A slider for a RAW setting whose untouched value comes from the camera and RAW engine.
    private func rawSlider(
        _ label: String,
        keyPath: WritableKeyPath<RawSettings, Double?>,
        range: ClosedRange<Double>,
        defaultValue: Double
    ) -> some View {
        let current = store.selectedAdjustments.raw[keyPath: keyPath]
        let value = current ?? defaultValue
        return VStack(spacing: 4) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                if current != nil {
                    Button {
                        store.updateAdjustments { $0.raw[keyPath: keyPath] = nil }
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                    .help("Back to the camera default")
                }
                Text(value, format: .number.precision(.fractionLength(2)))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(current == nil ? .secondary : .primary)
                    .frame(width: 44, alignment: .trailing)
            }
            Slider(
                value: Binding(
                    get: { store.selectedAdjustments.raw[keyPath: keyPath] ?? defaultValue },
                    set: { newValue in store.updateAdjustments { $0.raw[keyPath: keyPath] = newValue } }
                ),
                in: range,
                onEditingChanged: { editing in
                    if editing { store.beginAdjustmentEdit() } else { store.endAdjustmentEdit() }
                }
            )
            .tint(.orange)
            .accessibilityLabel(label)
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
        HStack(spacing: 6) {
            Button("Fit") {
                store.exitZoom100()
                zoom.reset()
            }
            .disabled(store.selectedAsset == nil || (zoom.isFitted && !store.isZoom100))

            Button {
                store.toggleZoom100()
            } label: {
                Label("100%", systemImage: "plus.magnifyingglass")
            }
            .tint(store.isZoom100 ? .orange : nil)
            .disabled(store.selectedAsset == nil || isCropping)
            .help("Pixel-perfect focus view (Z). Use the wheel over the photo for continuous zoom.")

            Text(store.isZoom100 ? "100%" : String(format: "%.1f×", zoom.scale))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
        .buttonStyle(.bordered)
    }

    private func zoomPhoto(by delta: CGFloat, precise: Bool, at pointer: CGPoint, viewport: CGSize) {
        guard let image = zoomImageSize(in: viewport) else { return }
        if store.isZoom100 {
            let fullSize = store.focusFullSize.width > 0 ? store.focusFullSize
                : (store.currentGeometry?.finishedSize ?? image)
            zoom.matchPixelView(
                center: store.zoomCenter, fullImage: fullSize, displayScale: displayScale,
                viewport: viewport, preview: image
            )
            store.exitZoom100()
        }
        zoom.zoom(by: delta, precise: precise, at: pointer, viewport: viewport, image: image)
    }

    private func zoomImageSize(in viewport: CGSize) -> CGSize? {
        guard let image = store.renderedPreview ?? store.originalPreview else { return nil }
        return store.previewMode == .sideBySide ? viewport : image.size
    }

    private func beginCrop() {
        guard store.selectedAsset != nil else { return }
        store.previewMode = .edited
        // The store renders the uncropped frame while editing, so the stored crop maps
        // directly onto the visible image.
        store.beginCropEditing()
        let stored = store.selectedAdjustments.cropRect
        draftCropRect = stored.map {
            CGRect(x: $0.x, y: 1 - $0.y - $0.height, width: $0.width, height: $0.height)
        }
        isCropping = true
    }

    private func applyCrop() {
        store.applyCropEditing(displayRect: draftCropRect)
        draftCropRect = nil
        isCropping = false
    }

    private func cancelCrop() {
        store.cancelCropEditing()
        draftCropRect = nil
        isCropping = false
    }

    private func resetPreviewViewport() {
        // Leaving a photo mid-crop discards the draft and closes its undo group.
        if isCropping {
            cancelCrop()
        }
        draftCropRect = nil
        isCropping = false
        zoom.reset()
    }
}
