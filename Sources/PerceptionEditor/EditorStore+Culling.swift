import AppKit

/// A photo thumbnail together with what it was rendered from, so stale ones are never shown.
struct PhotoThumbnail {
    var image: NSImage
    var url: URL
    var adjustments: PhotoAdjustments

    func matches(url: URL, adjustments: PhotoAdjustments) -> Bool {
        self.url == url && self.adjustments == adjustments
    }
}

extension EditorStore {
    // MARK: - Visible photos

    /// Photos passing the current filter, in capture order.
    var visiblePhotos: [MediaAsset] {
        project.media
            .filter { $0.kind == .photo && filter.matches($0) }
            .sorted(by: Self.captureOrder)
    }

    var allPhotos: [MediaAsset] {
        project.media.filter { $0.kind == .photo }.sorted(by: Self.captureOrder)
    }

    private static func captureOrder(_ a: MediaAsset, _ b: MediaAsset) -> Bool {
        if a.displayDate != b.displayDate { return a.displayDate < b.displayDate }
        return a.filename.localizedStandardCompare(b.filename) == .orderedAscending
    }

    /// 1-based position of the selected photo among the visible ones, if it is visible.
    var selectedPosition: Int? {
        guard let selectedAssetID else { return nil }
        return visiblePhotos.firstIndex(where: { $0.id == selectedAssetID }).map { $0 + 1 }
    }

    func count(of flag: PhotoFlag) -> Int {
        project.media.filter { $0.kind == .photo && $0.flag == flag }.count
    }

    // MARK: - Selection

    func selectAdjacent(_ offset: Int) {
        let photos = visiblePhotos
        guard !photos.isEmpty else { return }

        let target: MediaAsset
        if let current = photos.firstIndex(where: { $0.id == selectedAssetID }) {
            let index = min(max(0, current + offset), photos.count - 1)
            guard index != current else { return }
            target = photos[index]
        } else {
            target = photos[offset < 0 ? photos.count - 1 : 0]
        }
        select(target)
    }

    /// ⌘-click in the grid: add or remove one photo from the selection.
    func toggleSelection(_ asset: MediaAsset) {
        if selectedAssetIDs.contains(asset.id), selectedAssetIDs.count > 1 {
            selectedAssetIDs.remove(asset.id)
            if selectedAssetID == asset.id { selectedAssetID = selectedAssetIDs.first }
        } else {
            selectedAssetIDs.insert(asset.id)
            selectedAssetID = asset.id
        }
        refreshLoupe()
    }

    /// Shift-click in the grid: select everything between the current photo and `asset`.
    func extendSelection(to asset: MediaAsset) {
        let photos = visiblePhotos
        guard let anchorID = selectedAssetID,
              let anchor = photos.firstIndex(where: { $0.id == anchorID }),
              let end = photos.firstIndex(where: { $0.id == asset.id })
        else {
            select(asset)
            return
        }
        selectedAssetIDs = Set(photos[min(anchor, end) ... max(anchor, end)].map(\.id))
    }

    func selectAllVisible() {
        selectedAssetIDs = Set(visiblePhotos.map(\.id))
    }

    /// Photos that rating, flag, and label commands apply to: the multi-selection when the
    /// current photo is part of it, otherwise just the current photo.
    var commandTargetIDs: [UUID] {
        guard let selectedAssetID else { return [] }
        if selectedAssetIDs.count > 1, selectedAssetIDs.contains(selectedAssetID) {
            return Array(selectedAssetIDs)
        }
        return [selectedAssetID]
    }

    // MARK: - Rating, flag, label

    func setFlag(_ flag: PhotoFlag, for ids: [UUID]? = nil) {
        let targets = Set(ids ?? commandTargetIDs)
        guard !targets.isEmpty else { return }
        for index in project.media.indices where targets.contains(project.media[index].id) {
            project.media[index].flag = flag
        }
        statusMessage = message(for: flag, count: targets.count)
    }

    func setRating(_ rating: Int, for ids: [UUID]? = nil) {
        let targets = Set(ids ?? commandTargetIDs)
        let clamped = min(5, max(0, rating))
        guard !targets.isEmpty else { return }
        for index in project.media.indices where targets.contains(project.media[index].id) {
            project.media[index].rating = clamped
        }
        statusMessage = clamped == 0 ? "Cleared rating" : "Rated \(String(repeating: "★", count: clamped))"
    }

    /// Sets a color label, or removes it when every target already has it (as Lightroom does).
    func toggleLabel(_ label: ColorLabel, for ids: [UUID]? = nil) {
        let targets = Set(ids ?? commandTargetIDs)
        guard !targets.isEmpty else { return }
        let allHaveLabel = project.media
            .filter { targets.contains($0.id) }
            .allSatisfy { $0.colorLabel == label }
        for index in project.media.indices where targets.contains(project.media[index].id) {
            project.media[index].colorLabel = allHaveLabel ? nil : label
        }
        statusMessage = allHaveLabel ? "Cleared color label" : "Labeled \(label.title)"
    }

    func setLabel(_ label: ColorLabel?, for ids: [UUID]? = nil) {
        let targets = Set(ids ?? commandTargetIDs)
        for index in project.media.indices where targets.contains(project.media[index].id) {
            project.media[index].colorLabel = label
        }
    }

    private func message(for flag: PhotoFlag, count: Int) -> String {
        let noun = count == 1 ? "photo" : "\(count) photos"
        switch flag {
        case .picked: return "Picked \(noun)"
        case .rejected: return "Rejected \(noun)"
        case .unflagged: return "Cleared flag on \(noun)"
        }
    }

    // MARK: - Commands and keys

    /// Runs a culling command. Returns false when it does not apply to the current state.
    @discardableResult
    func perform(_ command: CullCommand) -> Bool {
        let hasPhoto = selectedAsset?.kind == .photo
        switch command {
        case .flag(let flag):
            guard hasPhoto else { return false }
            let advance = autoAdvance && workspace == .cull && commandTargetIDs.count == 1
            setFlag(flag)
            if advance { selectAdjacent(1) }
        case .rating(let rating):
            guard hasPhoto else { return false }
            setRating(rating)
        case .toggleLabel(let label):
            guard hasPhoto else { return false }
            toggleLabel(label)
        case .next:
            guard !visiblePhotos.isEmpty else { return false }
            selectAdjacent(1)
        case .previous:
            guard !visiblePhotos.isEmpty else { return false }
            selectAdjacent(-1)
        case .toggleCompare:
            guard workspace == .cull, hasPhoto else { return false }
            toggleCompare()
        case .toggleFullScreen:
            NSApp.keyWindow?.toggleFullScreen(nil)
        case .openInDevelop:
            guard hasPhoto else { return false }
            workspace = .photo
        case .toggleZoom:
            guard hasPhoto, workspace == .cull || workspace == .photo else { return false }
            toggleZoom100()
        case .exitZoom:
            guard isZoom100 else { return false }
            exitZoom100()
        }
        return true
    }

    /// Single-key shortcuts from the app's key monitor. Returns true when the key was used.
    func handleKey(_ characters: String) -> Bool {
        if characters == "\\" {
            guard workspace == .photo, selectedAsset != nil else { return false }
            toggleBeforeAfter()
            return true
        }

        guard let command = CullKeyMap.command(for: characters) else { return false }
        switch workspace {
        case .cull:
            return perform(command)
        case .library:
            switch command {
            case .toggleCompare, .toggleZoom, .exitZoom: return false
            default: return perform(command)
            }
        case .photo:
            // Sliders and the crop editor own the arrow keys and Return here.
            switch command {
            case .flag, .rating, .toggleLabel, .toggleFullScreen, .toggleZoom, .exitZoom:
                return perform(command)
            default: return false
            }
        case .video, .export, .agents:
            return false
        }
    }

    // MARK: - Compare

    func toggleCompare() {
        exitZoom100()
        if compareAssetID != nil {
            compareAssetID = nil
            compareImage = nil
        } else {
            compareAssetID = selectedAssetID
            refreshLoupe()
        }
    }

    // MARK: - Loupe previews

    func workspaceDidChange() {
        if isZoom100, workspace != .cull, workspace != .photo { exitZoom100() }
        switch workspace {
        case .cull:
            refreshLoupe()
        case .photo, .export:
            refreshPreview()
        default:
            break
        }
    }

    func filterDidChange() {
        // Keep a valid selection when the filter hides the current photo and nothing else is chosen.
        if let selectedAssetID, !visiblePhotos.contains(where: { $0.id == selectedAssetID }),
           let first = visiblePhotos.first, selectedAssetIDs.count <= 1 {
            select(first)
        }
    }

    /// Shows the selected photo's preview, then warms the cache around it.
    func refreshLoupe() {
        guard workspace == .cull else { return }
        guard let asset = selectedAsset, asset.kind == .photo else {
            loupeImage = nil
            return
        }

        if let cached = cullCache.image(for: asset) {
            loupeImage = cached
        }
        if let compareID = compareAssetID, let pinned = project.media.first(where: { $0.id == compareID }) {
            compareImage = cullCache.image(for: pinned) ?? compareImage
            cullCache.prefetch([pinned])
        }

        // Current photo first, then a few ahead (culling mostly moves forward) and one behind.
        let photos = visiblePhotos
        var wanted = [asset]
        if let index = photos.firstIndex(where: { $0.id == asset.id }) {
            wanted += photos[(index + 1)...].prefix(4)
            wanted += photos[..<index].suffix(2).reversed()
        }
        cullCache.prefetch(wanted)
    }

    func cullPreviewLoaded(_ id: UUID) {
        guard workspace == .cull else { return }
        if id == selectedAssetID, let asset = selectedAsset, let image = cullCache.image(for: asset) {
            loupeImage = image
        }
        if id == compareAssetID, let asset = project.media.first(where: { $0.id == id }),
           let image = cullCache.image(for: asset) {
            compareImage = image
        }
    }

    // MARK: - Removing photos

    /// Takes photos out of the project. The files are not touched.
    func removeFromProject(_ ids: [UUID]) {
        let targets = Set(ids)
        let photos = project.media.filter { targets.contains($0.id) && $0.kind == .photo }
        guard !photos.isEmpty else { return }
        let removed = Set(photos.map(\.id))

        // Move the selection to a neighbor before the photos disappear.
        if let current = selectedAssetID, removed.contains(current) {
            let ordered = visiblePhotos
            let index = ordered.firstIndex(where: { $0.id == current }) ?? 0
            let neighbor = ordered[index...].first(where: { !removed.contains($0.id) })
                ?? ordered[..<index].last(where: { !removed.contains($0.id) })
            selectedAssetID = neighbor?.id
            selectedAssetIDs = neighbor.map { [$0.id] } ?? []
        }

        project.media.removeAll { removed.contains($0.id) }
        for id in removed {
            project.adjustmentsByAssetID[id] = nil
            photoThumbnailsForget(id)
            cullCache.remove(id)
        }
        if compareAssetID.map(removed.contains) == true {
            compareAssetID = nil
            compareImage = nil
        }
        selectedAssetIDs.subtract(removed)
        statusMessage = "Removed \(photos.count) photo\(photos.count == 1 ? "" : "s") from the project"
        refreshLoupe()
        refreshPreview()
    }

    /// Rejected photos whose original lives inside this shoot's own `Originals` folder.
    /// Anything referenced from elsewhere (another drive, a Lightroom folder) is never a candidate.
    var trashableRejects: [MediaAsset] {
        guard let root = originalsFolder?.standardizedFileURL.path else { return [] }
        return project.media.filter {
            $0.kind == .photo && $0.flag == .rejected
                && $0.url.standardizedFileURL.path.hasPrefix(root + "/")
        }
    }

    var rejectedCount: Int { count(of: .rejected) }

    /// Moves rejected originals to the Trash (recoverable) after confirmation, then removes
    /// them from the project. Backups and files outside the shoot's Originals folder are untouched.
    func deleteRejected() {
        let candidates = trashableRejects
        let outside = rejectedCount - candidates.count

        guard !candidates.isEmpty else {
            lastError = rejectedCount == 0
                ? "There are no rejected photos."
                : "The rejected photos are stored outside this shoot's Originals folder, so they were left alone. Use Remove from Project instead."
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move \(candidates.count) rejected photo\(candidates.count == 1 ? "" : "s") to the Trash?"
        var detail = "The originals in this shoot's Originals folder move to the Trash, where you can still recover them. Backup copies are not touched."
        if outside > 0 {
            detail += " \(outside) rejected photo\(outside == 1 ? " is" : "s are") stored elsewhere and will be left alone."
        }
        alert.informativeText = detail
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var trashed: [UUID] = []
        var failures = 0
        for asset in candidates {
            do {
                try FileManager.default.trashItem(at: asset.url, resultingItemURL: nil)
                trashed.append(asset.id)
            } catch {
                // An original that is already gone still leaves the project.
                if FileManager.default.fileExists(atPath: asset.url.path) {
                    failures += 1
                } else {
                    trashed.append(asset.id)
                }
            }
        }
        removeFromProject(trashed)
        statusMessage = "Moved \(trashed.count) rejected photo\(trashed.count == 1 ? "" : "s") to the Trash"
        if failures > 0 {
            lastError = "\(failures) file\(failures == 1 ? "" : "s") could not be moved to the Trash and stayed in the project."
        }
    }

    // MARK: - Shoot folders

    /// The folder holding this shoot's copied originals, when the project lives in a shoot folder.
    var originalsFolder: URL? {
        projectURL?.deletingLastPathComponent().appendingPathComponent("Originals", isDirectory: true)
    }

    // MARK: - Autosave

    func autosaveIfNeeded() {
        guard let projectURL, hasUnsavedChanges else { return }
        do {
            try document.save(project, to: projectURL)
            lastSavedProject = project
        } catch {
            statusMessage = "Autosave failed: \(error.localizedDescription)"
        }
    }
}
