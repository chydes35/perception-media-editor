import AppKit
import UniformTypeIdentifiers

extension EditorStore {
    var selectedPhotosForExport: [MediaAsset] {
        let ids = selectedAssetIDs.isEmpty ? Set([selectedAssetID].compactMap { $0 }) : selectedAssetIDs
        return project.media.filter { $0.kind == .photo && ids.contains($0.id) }
    }

    func chooseBatchExportFolder(recipe: BatchExportRecipe) {
        do {
            try recipe.validate()
            guard !selectedPhotosForExport.isEmpty else { throw BatchExportError.noPhotosSelected }
        } catch {
            lastError = error.localizedDescription
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Choose Batch Export Folder"
        panel.prompt = "Export Here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            try startBatchExport(to: folder, recipe: recipe)
        } catch {
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    func startBatchExport(to folder: URL, recipe: BatchExportRecipe) throws -> Task<Void, Never> {
        try recipe.validate()
        guard !isExporting else { throw BatchExportError.alreadyExporting }
        let assets = selectedPhotosForExport
        guard !assets.isEmpty else { throw BatchExportError.noPhotosSelected }
        let items = assets.map { asset in
            BatchExportItem(
                id: asset.id,
                source: asset.url,
                adjustments: project.adjustmentsByAssetID[asset.id] ?? .neutral
            )
        }
        let originals = project.media.map(\.url)
        let generation = projectGeneration
        let exportFile = batchPhotoExporter
        isExporting = true
        batchExportState = BatchExportState(total: items.count)
        statusMessage = "Exporting \(items.count) photo\(items.count == 1 ? "" : "s")…"

        let task = Task { [weak self] in
            guard let self else { return }
            let renderer = PhotoRenderer(workingCacheLimit: 0, memoryTargetMB: 128)
            var reserved = Set<String>()
            for item in items {
                guard generation == projectGeneration else { return }
                if Task.isCancelled { break }
                batchExportState.currentFilename = item.filename
                do {
                    let destination = try BatchExportPlanner.destination(
                        for: item, in: folder, suffix: recipe.filenameSuffix,
                        reserved: &reserved, protecting: originals
                    )
                    if let exportFile {
                        try await exportFile(item, destination, recipe, originals)
                    } else {
                        try await renderer.export(
                            url: item.source, adjustments: item.adjustments, to: destination,
                            type: .jpeg, quality: recipe.jpegQuality,
                            protectedOriginals: originals, longEdgePixels: recipe.longEdgePixels,
                            replaceExisting: false
                        )
                    }
                    guard generation == projectGeneration else { return }
                    batchExportState.results.append(BatchExportFileResult(
                        id: item.id, sourceName: item.filename, output: destination, error: nil
                    ))
                } catch is CancellationError {
                    break
                } catch {
                    guard generation == projectGeneration else { return }
                    batchExportState.results.append(BatchExportFileResult(
                        id: item.id, sourceName: item.filename, output: nil,
                        error: error.localizedDescription
                    ))
                }
                batchExportState.completed += 1
            }
            guard generation == projectGeneration else { return }
            batchExportState.wasCancelled = Task.isCancelled
            batchExportState.currentFilename = nil
            isExporting = false
            batchExportTask = nil
            let failures = batchExportState.results.filter { !$0.succeeded }.count
            statusMessage = Task.isCancelled
                ? "Batch export stopped after \(batchExportState.completed) of \(items.count) photos"
                : "Batch export finished: \(batchExportState.completed - failures) saved, \(failures) failed"
        }
        batchExportTask = task
        return task
    }

    func cancelBatchExport() {
        batchExportTask?.cancel()
        if batchExportTask != nil { statusMessage = "Stopping batch export…" }
    }

    func invalidateBatchExport() {
        batchExportTask?.cancel()
        batchExportTask = nil
        batchExportState = BatchExportState()
        isExporting = false
    }
}
