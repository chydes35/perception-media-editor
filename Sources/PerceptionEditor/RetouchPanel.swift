import SwiftUI

struct RetouchPanel: View {
    @EnvironmentObject private var store: EditorStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                tool(.heal, icon: "bandage", help: "Paint a blemish; color and brightness blend with its surroundings")
                tool(.clone, icon: "square.on.square", help: "Copy detail from a chosen source point")
            }

            if store.retouchTool != nil {
                if store.retouchTool == .clone {
                    HStack {
                        Button(store.retouchPickingSource ? "Click source on photo" : "Set source") {
                            store.retouchPickingSource = true
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        Spacer()
                        if store.cloneSource != nil {
                            Text("Source set").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Text("Click a clean area for the source, then paint the area to copy. Hold ⌥ and click to choose another source.")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Click or paint over a spot. Drag the source pin if the suggested area is unsuitable.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                slider("Size", value: $store.retouchSize, range: 0.005 ... 0.3, scale: 100, format: "%.1f%%")
                slider("Feather", value: $store.retouchFeather, range: 0 ... 1, scale: 100, format: "%.0f%%")
                slider("Opacity", value: $store.retouchOpacity, range: 0 ... 1, scale: 100, format: "%.0f%%")
            }

            if !store.retouches.isEmpty {
                VStack(spacing: 3) {
                    ForEach(Array(store.retouches.enumerated()), id: \.element.id) { index, stroke in
                        row(stroke, number: index + 1)
                    }
                }
            } else if store.retouchTool == nil {
                Text("Choose Heal to remove spots or Clone to copy detail from a source you select.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            if let selected = store.selectedRetouch {
                Divider()
                Text("Selected \(selected.kind.title.lowercased()) repair")
                    .font(.caption).foregroundStyle(.secondary)
                slider("Size", value: binding(selected.id, \.size), range: 0.005 ... 0.3, scale: 100, format: "%.1f%%", edit: true)
                slider("Feather", value: binding(selected.id, \.feather), range: 0 ... 1, scale: 100, format: "%.0f%%", edit: true)
                slider("Opacity", value: binding(selected.id, \.opacity), range: 0 ... 1, scale: 100, format: "%.0f%%", edit: true)
            }

            if store.isRetouchEditing {
                Button("Done") { store.endRetouchEditing() }
                    .buttonStyle(.borderless).font(.caption)
            }
        }
        .disabled(store.selectedAsset?.kind != .photo)
    }

    private func tool(_ kind: RetouchKind, icon: String, help: String) -> some View {
        let selected = store.retouchTool == kind
        return Button { store.chooseRetouchTool(kind) } label: {
            Label(kind.title, systemImage: icon)
                .font(.caption)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(selected ? Color.orange.opacity(0.22) : Color(nsColor: .windowBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .stroke(selected ? Color.orange : Color.gray.opacity(0.25), lineWidth: selected ? 1.5 : 0.5))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func row(_ stroke: RetouchStroke, number: Int) -> some View {
        HStack(spacing: 5) {
            Button { store.updateRetouch(stroke.id) { $0.isEnabled.toggle() } } label: {
                Image(systemName: stroke.isEnabled ? "eye" : "eye.slash")
                    .frame(width: 16)
            }
            .buttonStyle(.borderless)
            .help(stroke.isEnabled ? "Hide repair" : "Show repair")
            Button { store.selectRetouch(stroke.id) } label: {
                HStack {
                    Image(systemName: stroke.kind == .heal ? "bandage" : "square.on.square")
                    Text("\(stroke.kind.title) \(number)")
                    Spacer()
                }
                .font(.caption)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { store.deleteRetouch(stroke.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Delete repair")
        }
        .padding(5)
        .background(store.selectedRetouchID == stroke.id ? Color.orange.opacity(0.15) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5))
    }

    private func binding(_ id: UUID, _ keyPath: WritableKeyPath<RetouchStroke, Double>) -> Binding<Double> {
        Binding(
            get: { store.retouches.first { $0.id == id }?[keyPath: keyPath] ?? 0 },
            set: { value in store.updateRetouch(id) { $0[keyPath: keyPath] = value } }
        )
    }

    private func slider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>,
                        scale: Double, format: String, edit: Bool = false) -> some View {
        VStack(spacing: 2) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(String(format: format, value.wrappedValue * scale))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, onEditingChanged: { editing in
                guard edit else { return }
                if editing { store.beginAdjustmentEdit() } else { store.endAdjustmentEdit() }
            })
            .tint(.orange)
        }
    }
}
