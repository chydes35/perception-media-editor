import Foundation

extension EditorStore {
    /// Snapshots the current selection and its adjustments and hands them to the Studio OS queue.
    /// After this returns, editing or switching projects cannot change what is delivered.
    func sendSelectedToStudioOS(to destination: StudioOSDestination) {
        let assets = selectedPhotosForExport
        guard !assets.isEmpty else {
            lastError = BatchExportError.noPhotosSelected.localizedDescription
            return
        }
        let items = assets.map { asset in
            StudioOSSendItem(
                assetID: asset.id, source: asset.url,
                adjustments: project.adjustmentsByAssetID[asset.id] ?? .neutral
            )
        }
        let originals = project.media.map(\.url)
        let controller = studioOS
        Task { @MainActor in
            do {
                try await controller.enqueue(
                    items: items, destination: destination, recipe: BatchExportRecipe(),
                    protecting: originals
                )
                statusMessage = "Sending \(items.count) photo\(items.count == 1 ? "" : "s") to Studio OS…"
            } catch {
                lastError = error.localizedDescription
            }
        }
    }
}
