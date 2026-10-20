import SwiftUI

struct ExportWorkspace: View {
    @EnvironmentObject private var store: EditorStore
    @State private var recipe = BatchExportRecipe()

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Export")
                    .font(.largeTitle.bold())
                Text("Deliver the selected photos with a saved recipe, or export one photo in any format.")
                    .foregroundStyle(.secondary)

                GroupBox("Selection") {
                    HStack {
                        Image(systemName: "photo")
                        Text("\(store.selectedPhotosForExport.count) photo\(store.selectedPhotosForExport.count == 1 ? "" : "s") selected")
                        Spacer()
                    }
                    .padding(8)
                }

                GroupBox("Export recipe") {
                    ExportRecipeEditor(
                        library: store.exportRecipes,
                        recipe: $recipe,
                        report: { store.lastError = $0 }
                    )
                }

                HStack {
                    Button {
                        store.chooseBatchExportFolder(recipe: recipe)
                    } label: {
                        Label("Export Selected Photos", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(store.selectedPhotosForExport.isEmpty || store.isExporting)

                    if store.isExporting, store.batchExportTask != nil {
                        Button("Stop") { store.cancelBatchExport() }
                    }
                }
                .controlSize(.large)

                if store.batchExportState.total > 0 {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(
                            value: Double(store.batchExportState.completed),
                            total: Double(store.batchExportState.total)
                        )
                        Text("\(store.batchExportState.completed) of \(store.batchExportState.total) complete")
                            .font(.caption)
                        if let filename = store.batchExportState.currentFilename {
                            Text("Exporting \(filename)…").font(.caption)
                        }
                        if store.batchExportState.wasCancelled {
                            Text("Export stopped").font(.caption)
                        }
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(store.batchExportState.results) { result in
                                    Label(
                                        result.succeeded
                                            ? "\(result.sourceName) → \(result.output?.lastPathComponent ?? "")"
                                            : "\(result.sourceName): \(result.error ?? "Export failed")",
                                        systemImage: result.succeeded ? "checkmark.circle" : "exclamationmark.triangle"
                                    )
                                    .font(.caption)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 180, alignment: .top)
                }

                Button("Export one photo with this recipe…") { store.exportSelectedPhoto() }
                    .disabled(store.selectedAsset?.kind != .photo || store.isExporting)

                Spacer()
            }
            .padding(36)
            .frame(maxWidth: 560)
            }
            .frame(maxWidth: 560)
            .onAppear { recipe = store.exportRecipes.selected.recipe }

            Divider()

            ZStack {
                Color.black.opacity(0.92)
                if let image = store.renderedPreview {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(48)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 70))
                        .foregroundStyle(.white.opacity(0.22))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
