import SwiftUI

/// The left column of Develop: presets grouped by category, then this photo's edit history.
struct PresetPanel: View {
    @EnvironmentObject private var store: EditorStore
    @State private var collapsed: Set<String> = []
    @State private var renaming: PhotoPreset?
    @State private var renameText = ""
    @State private var movingToNewCategory: PhotoPreset?
    @State private var categoryText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if store.selectedAssetIDs.count > 1 {
                Label("Applies to \(store.selectedAssetIDs.count) selected photos", systemImage: "square.stack.3d.up")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(store.presetCategories, id: \.self) { category in
                        categorySection(category)
                    }
                }
            }

            historySection

            Button("Reset Adjustments", systemImage: "arrow.counterclockwise") {
                store.resetAdjustments()
            }
            .buttonStyle(.bordered)
            .disabled(store.selectedAsset == nil)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .alert("Rename Preset", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let renaming { store.renameUserPreset(renaming, to: renameText) }
            }
            .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .alert("New Category", isPresented: Binding(
            get: { movingToNewCategory != nil },
            set: { if !$0 { movingToNewCategory = nil } }
        )) {
            TextField("Category name", text: $categoryText)
            Button("Cancel", role: .cancel) {}
            Button("Move") {
                if let movingToNewCategory { store.moveUserPreset(movingToNewCategory, toCategory: categoryText) }
            }
            .disabled(categoryText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    // MARK: Presets

    private var header: some View {
        HStack {
            Label("PRESETS", systemImage: "camera.filters")
                .font(.caption.weight(.bold))
                .tracking(1.1)
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                Button("Import Presets…") { store.importPresets() }
                Button("Export My Presets…") {
                    store.exportPresets(store.userPresets, suggestedName: "My Presets")
                }
                .disabled(store.userPresets.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Import or export presets")

            Button {
                store.isShowingSavePresetSheet = true
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("Save the current settings as a preset")
            .disabled(store.selectedAsset == nil)
        }
    }

    private func categorySection(_ category: String) -> some View {
        let presets = store.presets(in: category)
        let isCollapsed = collapsed.contains(category)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                if isCollapsed { collapsed.remove(category) } else { collapsed.insert(category) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 10)
                    Text(category.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.8)
                    Spacer()
                    Text("\(presets.count)")
                        .font(.system(size: 9))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(category), \(presets.count) presets")
            .accessibilityHint(isCollapsed ? "Expand" : "Collapse")

            if !isCollapsed {
                ForEach(presets) { preset in
                    presetRow(preset)
                }
            }
        }
    }

    private func presetRow(_ preset: PhotoPreset) -> some View {
        Button {
            store.apply(preset)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name)
                    .font(.callout.weight(.semibold))
                if preset.effectiveGroups != AdjustmentGroup.basics {
                    Text(groupSummary(preset))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(store.selectedAsset == nil)
        .contextMenu {
            Button("Apply") { store.apply(preset) }
            if store.isUserPreset(preset) {
                Divider()
                Button("Update with Current Settings") {
                    store.updateUserPreset(preset, groups: preset.effectiveGroups)
                }
                Button("Rename…") {
                    renameText = preset.name
                    renaming = preset
                }
                Menu("Move to Category") {
                    ForEach(store.presetCategories, id: \.self) { category in
                        Button(category) { store.moveUserPreset(preset, toCategory: category) }
                            .disabled(category == preset.category)
                    }
                    Divider()
                    Button("New Category…") {
                        categoryText = ""
                        movingToNewCategory = preset
                    }
                }
                Button("Export…") { store.exportPresets([preset], suggestedName: preset.name) }
                Divider()
                Button("Delete Preset", role: .destructive) { store.deleteUserPreset(preset) }
            } else {
                Divider()
                Button("Export…") { store.exportPresets([preset], suggestedName: preset.name) }
            }
        }
        .accessibilityLabel(preset.name)
    }

    private func groupSummary(_ preset: PhotoPreset) -> String {
        AdjustmentGroup.allCases
            .filter { preset.effectiveGroups.contains($0) }
            .map(\.title)
            .joined(separator: " · ")
    }

    // MARK: History

    private var historySection: some View {
        let entries = store.selectedHistory
        return VStack(alignment: .leading, spacing: 6) {
            Label("HISTORY", systemImage: "clock.arrow.circlepath")
                .font(.caption.weight(.bold))
                .tracking(1.1)
                .foregroundStyle(.secondary)

            if entries.count < 2 {
                Text("Edits to this photo appear here. Click a step to go back to it.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(entries.reversed()) { entry in
                            historyRow(entry)
                        }
                    }
                }
                .frame(maxHeight: 170)
            }
        }
    }

    private func historyRow(_ entry: HistoryEntry) -> some View {
        let isCurrent = entry.adjustments == store.selectedAdjustments
        return Button {
            store.restoreHistory(entry)
        } label: {
            HStack {
                Text(entry.name)
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                Text(entry.date, format: .dateTime.hour().minute())
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isCurrent ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(entry.name)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

// MARK: - Sheets

/// A checklist of the Develop panel's groups, used when saving a preset and when copying settings.
struct GroupChecklist: View {
    @Binding var groups: Set<AdjustmentGroup>
    let edited: Set<AdjustmentGroup>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button("All") { groups = Set(AdjustmentGroup.allCases) }
                Button("Edited") { groups = edited.subtracting([.whiteBalance]) }
                Button("None") { groups = [] }
                Spacer()
            }
            .buttonStyle(.borderless)
            .font(.caption)

            ForEach(AdjustmentGroup.allCases) { group in
                Toggle(isOn: Binding(
                    get: { groups.contains(group) },
                    set: { isOn in
                        if isOn { groups.insert(group) } else { groups.remove(group) }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(group.title)
                            if edited.contains(group) {
                                Circle().fill(Color.orange).frame(width: 6, height: 6)
                                    .accessibilityLabel("edited")
                            }
                        }
                        Text(group.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
            Text("A dot marks groups you have changed on this photo. White balance is off by default because it depends on the light each photo was taken in.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct SavePresetSheet: View {
    @EnvironmentObject private var store: EditorStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var category = PresetLibrary.defaultCategory
    @State private var newCategory = ""
    @State private var groups: Set<AdjustmentGroup> = []

    private static let newCategoryTag = "\u{0}new"

    private var chosenCategory: String {
        category == Self.newCategoryTag ? newCategory : category
    }

    private var categories: [String] {
        var all = store.presetCategories
        if !all.contains(PresetLibrary.defaultCategory) { all.append(PresetLibrary.defaultCategory) }
        return all
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save Preset").font(.title3.weight(.semibold))

            TextField("Preset name", text: $name)
                .textFieldStyle(.roundedBorder)

            Picker("Category", selection: $category) {
                ForEach(categories, id: \.self) { Text($0).tag($0) }
                Divider()
                Text("New Category…").tag(Self.newCategoryTag)
            }
            if category == Self.newCategoryTag {
                TextField("New category name", text: $newCategory)
                    .textFieldStyle(.roundedBorder)
            }

            GroupBox("Settings to include") {
                GroupChecklist(groups: $groups, edited: store.selectedAdjustments.editedGroups)
                    .padding(6)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    store.saveUserPreset(named: name, category: chosenCategory, groups: groups)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                    || groups.isEmpty
                    || (category == Self.newCategoryTag && newCategory.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .padding(22)
        .frame(width: 400)
        .onAppear {
            let edited = store.selectedAdjustments.editedGroups.subtracting([.whiteBalance])
            groups = edited.isEmpty ? AdjustmentGroup.basics : edited
        }
    }
}

struct CopySettingsSheet: View {
    @EnvironmentObject private var store: EditorStore
    @Environment(\.dismiss) private var dismiss
    let mode: CopySheetMode
    @State private var groups: Set<AdjustmentGroup> = []

    private var otherPhotos: Int {
        store.selectedAssetIDs.filter { $0 != store.selectedAssetID }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(mode == .copy ? "Copy Settings" : "Sync Settings").font(.title3.weight(.semibold))
            Text(mode == .copy
                 ? "Choose what to copy from \(store.selectedAsset?.filename ?? "this photo"). Paste it onto other photos with Paste Settings."
                 : "Copies the chosen settings from \(store.selectedAsset?.filename ?? "this photo") onto the other \(otherPhotos) selected photo\(otherPhotos == 1 ? "" : "s").")
                .font(.callout)
                .foregroundStyle(.secondary)

            GroupBox {
                GroupChecklist(groups: $groups, edited: store.selectedAdjustments.editedGroups)
                    .padding(6)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(mode == .copy ? "Copy" : "Sync") {
                    if mode == .copy {
                        store.copySettings(groups: groups)
                    } else {
                        store.syncSettings(groups: groups)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(groups.isEmpty || (mode == .sync && otherPhotos == 0))
            }
        }
        .padding(22)
        .frame(width: 400)
        .onAppear {
            let edited = store.selectedAdjustments.editedGroups.subtracting([.whiteBalance])
            groups = edited.isEmpty ? AdjustmentGroup.basics : edited
        }
    }
}
