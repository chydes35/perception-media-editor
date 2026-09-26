import AppKit
import UniformTypeIdentifiers

enum CopySheetMode: Equatable {
    case copy
    case sync
}

extension EditorStore {
    // MARK: - Applying looks

    /// Applies a preset to the selected photos (or just the current one). Only the groups the
    /// preset contains change; everything else about each photo is kept.
    func apply(_ preset: PhotoPreset, to ids: [UUID]? = nil) {
        let targets = ids ?? commandTargetIDs
        guard applyToPhotos(targets, label: "Preset: \(preset.name)", { preset.apply(to: $0) }) > 0 else { return }
        statusMessage = targets.count == 1
            ? "Applied \(preset.name)"
            : "Applied \(preset.name) to \(targets.count) photos"
    }

    /// Changes several photos as a single undo step. Returns how many photos changed.
    @discardableResult
    func applyToPhotos(
        _ ids: [UUID],
        label: String,
        _ transform: (PhotoAdjustments) -> PhotoAdjustments
    ) -> Int {
        let photoIDs = Set(ids).intersection(project.media.filter { $0.kind == .photo }.map(\.id))
        guard !photoIDs.isEmpty else { return 0 }

        let before = project.adjustmentsByAssetID
        for id in photoIDs {
            project.adjustmentsByAssetID[id] = transform(before[id] ?? .neutral)
        }
        let changed = photoIDs.filter { (before[$0] ?? .neutral) != project.adjustmentsByAssetID[$0] }.count

        nextHistoryLabel = label
        if activeAdjustmentSnapshot == nil {
            recordAdjustmentChange(before: before)
        } else {
            nextHistoryLabel = nil
        }
        refreshPreview()
        return changed
    }

    // MARK: - Copy, paste, sync

    var canPasteSettings: Bool { copiedSettings != nil && selectedAsset?.kind == .photo }

    func copySettings(groups: Set<AdjustmentGroup>) {
        guard let asset = selectedAsset, asset.kind == .photo, !groups.isEmpty else { return }
        copiedSettings = CopiedSettings(
            adjustments: selectedAdjustments.containing(groups),
            groups: groups,
            sourceName: asset.filename
        )
        statusMessage = "Copied settings from \(asset.filename)"
    }

    func pasteSettings(to ids: [UUID]? = nil) {
        guard let copied = copiedSettings else { return }
        let targets = ids ?? commandTargetIDs
        let changed = applyToPhotos(targets, label: "Paste from \(copied.sourceName)") {
            $0.applying(copied.adjustments, groups: copied.groups)
        }
        if changed > 0 {
            statusMessage = "Pasted settings onto \(targets.count) photo\(targets.count == 1 ? "" : "s")"
        }
    }

    /// Copies the current photo's settings onto every other selected photo.
    func syncSettings(groups: Set<AdjustmentGroup>) {
        guard let current = selectedAssetID, !groups.isEmpty else { return }
        copySettings(groups: groups)
        let others = selectedAssetIDs.filter { $0 != current }
        guard !others.isEmpty else {
            statusMessage = "Select more photos to sync settings to."
            return
        }
        pasteSettings(to: Array(others))
    }

    // MARK: - History

    var selectedHistory: [HistoryEntry] {
        guard let selectedAssetID else { return [] }
        return history[selectedAssetID] ?? []
    }

    func appendHistory(before snapshot: [UUID: PhotoAdjustments], label: String?) {
        for (id, after) in project.adjustmentsByAssetID {
            let old = snapshot[id] ?? .neutral
            guard old != after else { continue }

            var entries = history[id] ?? [HistoryEntry(name: "Start", adjustments: old)]
            entries.append(HistoryEntry(name: label ?? after.changeSummary(from: old), adjustments: after))
            if entries.count > HistoryEntry.limit {
                // Keep the starting point and the most recent steps.
                entries.removeSubrange(1 ..< entries.count - HistoryEntry.limit + 1)
            }
            history[id] = entries
        }
    }

    /// Returns the selected photo to the state after `entry`. The step is recorded like any
    /// other edit, so it can be undone and the history is never rewritten.
    func restoreHistory(_ entry: HistoryEntry) {
        guard selectedAdjustments != entry.adjustments else { return }
        nextHistoryLabel = "Back to \(entry.name)"
        updateAdjustments { $0 = entry.adjustments }
    }

    // MARK: - User presets

    var presetCategories: [String] {
        PresetLibrary.categories(builtIn: PhotoPreset.builtIns, user: userPresets)
    }

    func presets(in category: String) -> [PhotoPreset] {
        presets.filter { $0.category == category }
    }

    func isUserPreset(_ preset: PhotoPreset) -> Bool {
        userPresets.contains(where: { $0.id == preset.id })
    }

    /// Saves the selected photo's `groups` as a preset. A preset with the same name in the same
    /// category is replaced.
    @discardableResult
    func saveUserPreset(
        named name: String,
        category: String = PresetLibrary.defaultCategory,
        groups: Set<AdjustmentGroup>
    ) -> PhotoPreset? {
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        let categoryName = cleanedCategory.isEmpty ? PresetLibrary.defaultCategory : cleanedCategory
        guard !cleanedName.isEmpty, selectedAssetID != nil, !groups.isEmpty else { return nil }

        let saved: PhotoPreset
        if let index = userPresets.firstIndex(where: {
            $0.category == categoryName && $0.name.localizedCaseInsensitiveCompare(cleanedName) == .orderedSame
        }) {
            userPresets[index].adjustments = selectedAdjustments.containing(groups)
            userPresets[index].groups = groups
            saved = userPresets[index]
        } else {
            saved = PhotoPreset(
                name: cleanedName,
                category: categoryName,
                adjustments: selectedAdjustments.containing(groups),
                groups: groups
            )
            userPresets.append(saved)
        }
        persistUserPresets()
        statusMessage = "Saved preset \(cleanedName)"
        return saved
    }

    /// Replaces a user preset's settings with the selected photo's current ones.
    func updateUserPreset(_ preset: PhotoPreset, groups: Set<AdjustmentGroup>) {
        guard let index = userPresets.firstIndex(where: { $0.id == preset.id }),
              selectedAssetID != nil, !groups.isEmpty
        else { return }
        userPresets[index].adjustments = selectedAdjustments.containing(groups)
        userPresets[index].groups = groups
        persistUserPresets()
        statusMessage = "Updated preset \(userPresets.first(where: { $0.id == preset.id })?.name ?? preset.name)"
    }

    func renameUserPreset(_ preset: PhotoPreset, to name: String) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, let index = userPresets.firstIndex(where: { $0.id == preset.id }) else { return }
        // Read the stored preset, not the caller's copy, which may be out of date.
        let others = userPresets.filter { $0.id != preset.id }
        userPresets[index].name = PresetLibrary.uniqueName(cleaned, category: userPresets[index].category, in: others)
        persistUserPresets()
    }

    func moveUserPreset(_ preset: PhotoPreset, toCategory category: String) {
        let cleaned = category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, let index = userPresets.firstIndex(where: { $0.id == preset.id }) else { return }
        let others = userPresets.filter { $0.id != preset.id }
        let currentName = userPresets[index].name
        userPresets[index].category = cleaned
        userPresets[index].name = PresetLibrary.uniqueName(currentName, category: cleaned, in: others)
        persistUserPresets()
    }

    func deleteUserPreset(_ preset: PhotoPreset) {
        userPresets.removeAll(where: { $0.id == preset.id })
        persistUserPresets()
        statusMessage = "Deleted preset \(preset.name)"
    }

    private func persistUserPresets() {
        userPresets = PresetLibrary.sorted(userPresets)
        userPresetRepository.save(userPresets)
    }

    // MARK: - Preset files

    func exportPresets(_ presets: [PhotoPreset], suggestedName: String = "Presets") {
        guard !presets.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = "Export Presets"
        panel.allowedContentTypes = [UTType(filenameExtension: PresetFile.fileExtension) ?? .json]
        panel.nameFieldStringValue = "\(suggestedName).\(PresetFile.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try PresetLibrary.encode(presets).write(to: url, options: .atomic)
            statusMessage = "Exported \(presets.count) preset\(presets.count == 1 ? "" : "s")"
        } catch {
            lastError = error.localizedDescription
        }
    }

    func importPresets() {
        let panel = NSOpenPanel()
        panel.title = "Import Presets"
        panel.allowedContentTypes = [UTType(filenameExtension: PresetFile.fileExtension) ?? .json]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        importPresets(from: panel.urls)
    }

    func importPresets(from urls: [URL]) {
        var added = 0
        var skipped = 0
        for url in urls {
            do {
                let incoming = try PresetLibrary.decode(Data(contentsOf: url))
                let result = PresetLibrary.merge(existing: userPresets, incoming: incoming)
                userPresets = result.presets
                added += result.added
                skipped += result.skipped
            } catch {
                lastError = "\(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        persistUserPresets()
        statusMessage = "Imported \(added) preset\(added == 1 ? "" : "s")"
            + (skipped > 0 ? " (\(skipped) already in your library)" : "")
    }
}
