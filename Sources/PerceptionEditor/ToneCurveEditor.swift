import SwiftUI

/// A point-curve editor. Click the curve to add a point, drag a point to move it, and
/// ⌥-click a point to remove it. The photo's histogram is drawn behind the curve.
struct ToneCurveEditor: View {
    @EnvironmentObject private var store: EditorStore
    @Environment(\.adjustmentEditing) private var environmentEditing
    @State private var channel: ToneCurves.Channel = .rgb
    @State private var draggingIndex: Int?
    @State private var isEditing = false

    private let grabRadius = 0.05

    /// The environment's target, or the selected photo when it supplies none.
    private var editing: AdjustmentEditing { environmentEditing ?? store.photoAdjustmentEditing }

    private var curve: ToneCurve {
        editing.current.curves[channel] ?? .linear
    }

    private var lineColor: Color {
        switch channel {
        case .rgb: .primary
        case .red: .red
        case .green: .green
        case .blue: .blue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Channel", selection: $channel) {
                    ForEach(ToneCurves.Channel.allCases) { channel in
                        Text(channel.rawValue).tag(channel)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)

                Spacer()

                Menu {
                    ForEach(ToneCurve.presets, id: \.name) { preset in
                        Button(preset.name) { setCurve(preset.curve) }
                    }
                } label: {
                    Text("Presets").font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                if !editing.current.curves.isNeutral {
                    Button {
                        editing.resetCurves()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                    .help("Reset all curves")
                }
            }

            Canvas { context, size in
                draw(in: &context, size: size)
            }
            .aspectRatio(1, contentMode: .fit)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3), lineWidth: 0.5))
            .overlay {
                GeometryReader { geometry in
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                                .onChanged { value in drag(value.location, in: geometry.size) }
                                .onEnded { _ in endDrag() }
                        )
                }
            }
            .disabled(!editing.isAvailable)
            .accessibilityElement()
            .accessibilityLabel("\(channel.rawValue) tone curve")
            .accessibilityValue("\(curve.points.count) points")

            Text("Click to add a point, drag to move, ⌥-click to remove.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let s = min(size.width, size.height)

        // Grid
        var grid = Path()
        for i in 1 ..< 4 {
            let p = s * CGFloat(i) / 4
            grid.move(to: CGPoint(x: p, y: 0)); grid.addLine(to: CGPoint(x: p, y: s))
            grid.move(to: CGPoint(x: 0, y: p)); grid.addLine(to: CGPoint(x: s, y: p))
        }
        context.stroke(grid, with: .color(.gray.opacity(0.25)), lineWidth: 0.5)

        // Histogram behind the curve
        let histogram = histogramValues()
        if !histogram.isEmpty {
            var fill = Path()
            fill.move(to: CGPoint(x: 0, y: s))
            for (index, value) in histogram.enumerated() {
                let x = s * CGFloat(index) / CGFloat(histogram.count - 1)
                fill.addLine(to: CGPoint(x: x, y: s - s * 0.85 * CGFloat(value)))
            }
            fill.addLine(to: CGPoint(x: s, y: s))
            fill.closeSubpath()
            context.fill(fill, with: .color(lineColor.opacity(channel == .rgb ? 0.14 : 0.24)))
        }

        // Reference diagonal
        var diagonal = Path()
        diagonal.move(to: CGPoint(x: 0, y: s)); diagonal.addLine(to: CGPoint(x: s, y: 0))
        context.stroke(diagonal, with: .color(.gray.opacity(0.35)), style: StrokeStyle(lineWidth: 0.7, dash: [3, 3]))

        // The curve
        let table = curve.lookupTable(samples: 128)
        var line = Path()
        for (index, value) in table.enumerated() {
            let point = CGPoint(x: s * CGFloat(index) / CGFloat(table.count - 1), y: s - s * CGFloat(value))
            if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
        }
        context.stroke(line, with: .color(lineColor), lineWidth: 1.6)

        // Points
        for (index, point) in curve.points.enumerated() {
            let center = CGPoint(x: s * point.x, y: s - s * point.y)
            let radius: CGFloat = index == draggingIndex ? 5.5 : 4
            let dot = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            context.fill(dot, with: .color(Color(nsColor: .textBackgroundColor)))
            context.stroke(dot, with: .color(lineColor), lineWidth: 1.6)
        }
    }

    /// The photo's histogram for the selected channel, smoothed a little for display.
    private func histogramValues() -> [Double] {
        guard editing.showsPhotoHistogram else { return [] }
        let data = store.histogram
        guard data.hasValues else { return [] }
        let source: [Double]
        switch channel {
        case .red: source = data.red
        case .green: source = data.green
        case .blue: source = data.blue
        case .rgb: source = zip(zip(data.red, data.green), data.blue).map { max($0.0.0, $0.0.1, $0.1) }
        }
        return stride(from: 0, to: source.count, by: 4).map { start in
            let slice = source[start ..< min(source.count, start + 4)]
            return slice.reduce(0, +) / Double(slice.count)
        }
    }

    // MARK: Editing

    private func setCurve(_ new: ToneCurve) {
        editing.setCurve(new, channel: channel)
    }

    private func drag(_ location: CGPoint, in size: CGSize) {
        let s = min(size.width, size.height)
        guard s > 0 else { return }
        let target = CGPoint(
            x: min(1, max(0, location.x / s)),
            y: min(1, max(0, 1 - location.y / s))
        )

        if !isEditing {
            isEditing = true
            editing.beginEdit()

            let existing = curve.nearestPoint(to: target, radius: grabRadius)
            if NSEvent.modifierFlags.contains(.option), let existing {
                update { $0.removePoint(at: existing) }
                draggingIndex = nil
                return
            }
            if let existing {
                draggingIndex = existing
            } else {
                // A new point starts on the curve, so adding one does not change the shape until it is dragged.
                var updated = curve
                if let index = updated.addPoint(x: Double(target.x), y: updated.evaluate(Double(target.x))) {
                    draggingIndex = index
                    setWithoutUndo(updated)
                }
            }
        }

        if let index = draggingIndex {
            update { $0.movePoint(at: index, to: target) }
        }
    }

    private func endDrag() {
        guard isEditing else { return }
        isEditing = false
        draggingIndex = nil
        editing.endEdit()
    }

    private func update(_ change: (inout ToneCurve) -> Void) {
        var updated = curve
        change(&updated)
        setWithoutUndo(updated)
    }

    private func setWithoutUndo(_ new: ToneCurve) {
        editing.setCurve(new, channel: channel)
    }
}

// MARK: - HSL

/// Hue, saturation, and luminance for eight color bands.
struct HSLPanel: View {
    @EnvironmentObject private var store: EditorStore
    @Environment(\.adjustmentEditing) private var environmentEditing
    @State private var band: HSLBand = .red

    static func color(for band: HSLBand) -> Color {
        Color(hue: band.centerHue / 360, saturation: 0.85, brightness: 0.95)
    }

    private var editing: AdjustmentEditing { environmentEditing ?? store.photoAdjustmentEditing }

    private var hsl: HSLAdjustments {
        editing.current.hsl ?? HSLAdjustments()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                ForEach(HSLBand.allCases) { candidate in
                    Button {
                        band = candidate
                    } label: {
                        Circle()
                            .fill(Self.color(for: candidate))
                            .frame(width: 17, height: 17)
                            .overlay {
                                Circle()
                                    .stroke(Color.primary, lineWidth: band == candidate ? 2 : 0)
                            }
                            .overlay(alignment: .bottomTrailing) {
                                if !hsl[candidate].isNeutral {
                                    Circle().fill(Color.primary).frame(width: 6, height: 6)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .help(candidate.title)
                    .accessibilityLabel(candidate.title)
                    .accessibilityAddTraits(band == candidate ? .isSelected : [])
                }
                Spacer()
                if !hsl.isNeutral {
                    Button {
                        editing.resetHSL()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                    .help("Reset all colors")
                }
            }

            Text(band.title)
                .font(.caption.weight(.semibold))

            slider("Hue", keyPath: \.hue)
            slider("Saturation", keyPath: \.saturation)
            slider("Luminance", keyPath: \.luminance)
        }
    }

    private func slider(_ label: String, keyPath: WritableKeyPath<HSLBandAdjustment, Double>) -> some View {
        let value = hsl[band][keyPath: keyPath]
        return VStack(spacing: 4) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                if value != 0 {
                    Button {
                        set(0, keyPath)
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
                        get: { (value * 100).rounded() },
                        set: { set(min(100, max(-100, $0)) / 100, keyPath) }
                    ),
                    format: .number.precision(.fractionLength(0))
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 52)
            }
            Slider(
                value: Binding(get: { value }, set: { set($0, keyPath) }),
                in: -1 ... 1,
                onEditingChanged: { isDragging in
                    if isDragging { self.editing.beginEdit() } else { self.editing.endEdit() }
                }
            )
            .tint(Self.color(for: band))
            .disabled(!editing.isAvailable)
            .accessibilityLabel("\(band.title) \(label)")
        }
    }

    private func set(_ value: Double, _ keyPath: WritableKeyPath<HSLBandAdjustment, Double>) {
        editing.setHSL(value, band: band, keyPath: keyPath)
    }
}
