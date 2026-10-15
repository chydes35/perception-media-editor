import SwiftUI

struct ExportWorkspace: View {
    @EnvironmentObject private var store: EditorStore
    @State private var jpegQuality = 0.92
    @State private var longEdgePixels = 0
    @State private var filenameSuffix = "_edited"

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Export")
                        .font(.largeTitle.bold())
                    Text("Deliver selected photos as sRGB JPEGs, or export one photo as JPEG or PNG.")
                        .foregroundStyle(.secondary)

                    GroupBox("Selection") {
                        HStack {
                            Image(systemName: "photo")
                            Text("\(store.selectedPhotosForExport.count) photo\(store.selectedPhotosForExport.count == 1 ? "" : "s") selected")
                            Spacer()
                        }
                        .padding(8)
                    }

                    GroupBox("Batch JPEG recipe") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Quality")
                                Slider(value: $jpegQuality, in: 0.5...1, step: 0.05)
                                Text("\(Int((jpegQuality * 100).rounded()))%")
                                    .monospacedDigit()
                                    .frame(width: 44, alignment: .trailing)
                            }
                            Picker("Long edge", selection: $longEdgePixels) {
                                Text("Full resolution").tag(0)
                                Text("2,048 px").tag(2048)
                                Text("3,000 px").tag(3000)
                                Text("4,000 px").tag(4000)
                            }
                            HStack {
                                Text("Filename suffix")
                                TextField("_edited", text: $filenameSuffix)
                                    .textFieldStyle(.roundedBorder)
                            }
                            Text("Existing files receive a numbered name. Original photos are protected.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }

                    HStack {
                        Button {
                            store.chooseBatchExportFolder(recipe: BatchExportRecipe(
                                jpegQuality: jpegQuality,
                                longEdgePixels: longEdgePixels == 0 ? nil : longEdgePixels,
                                filenameSuffix: filenameSuffix
                            ))
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

                    StudioOSPanel(controller: store.studioOS)

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

                    Button("Export one photo as JPEG or PNG…") { store.exportSelectedPhoto() }
                        .disabled(store.selectedAsset?.kind != .photo || store.isExporting)
                }
                .padding(36)
            }
            .frame(maxWidth: 560)

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
