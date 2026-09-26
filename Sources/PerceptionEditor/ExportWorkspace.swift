import SwiftUI

struct ExportWorkspace: View {
    @EnvironmentObject private var store: EditorStore

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Export")
                    .font(.largeTitle.bold())
                Text("V0.2 exports the selected edited photo as a full-resolution JPEG or PNG in sRGB.")
                    .foregroundStyle(.secondary)

                GroupBox("Selected photo") {
                    HStack {
                        Image(systemName: "photo")
                        Text(store.selectedAsset?.filename ?? "No photo selected")
                        Spacer()
                    }
                    .padding(8)
                }

                GroupBox("Photo preset") {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Full resolution", systemImage: "arrow.up.left.and.arrow.down.right")
                        Label("sRGB color space", systemImage: "paintpalette")
                        Label("JPEG 92% or lossless PNG", systemImage: "doc")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }

                Button {
                    store.exportSelectedPhoto()
                } label: {
                    Label("Export Selected Photo", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.orange)
                .disabled(store.selectedAsset == nil)

                Spacer()
            }
            .padding(36)
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
