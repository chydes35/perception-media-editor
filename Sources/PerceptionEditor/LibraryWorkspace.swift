import SwiftUI

struct LibraryWorkspace: View {
    @EnvironmentObject private var store: EditorStore
    @State private var selection: String = "All Media"

    private let columns = [
        GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 14)
    ]

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 190, idealWidth: 220, maxWidth: 260)
            library
                .frame(minWidth: 700, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("PROJECT", items: ["All Media", "Photos", "Video", "Audio"])
            section("COLLECTIONS", items: ["Interview", "B-Roll", "Drone", "Music"])
            Spacer()
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func section(_ heading: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(heading)
                .font(.caption2.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
            ForEach(items, id: \.self) { item in
                Button {
                    selection = item
                } label: {
                    HStack {
                        Image(systemName: icon(for: item))
                            .frame(width: 18)
                        Text(item)
                        Spacer()
                        if item == "All Media" || item == "Photos" {
                            Text("\(store.project.media.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        selection == item ? Color.accentColor.opacity(0.14) : .clear,
                        in: RoundedRectangle(cornerRadius: 7)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(selection)
                        .font(.title2.weight(.semibold))
                    Text("Reference files stay in their original locations.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(store.project.media.count) ITEMS")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(20)

            Divider()

            if store.project.media.isEmpty {
                ContentUnavailableView {
                    Label("Your library is empty", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("Import JPEG, HEIC, PNG, TIFF, or camera RAW files to begin.")
                } actions: {
                    Button("Import Photos") { store.importMedia() }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(store.project.media) { asset in
                            MediaCard(asset: asset)
                                .onTapGesture {
                                    store.select(asset)
                                    store.workspace = .photo
                                }
                        }
                    }
                    .padding(20)
                }
            }
        }
    }

    private func icon(for item: String) -> String {
        switch item {
        case "Photos": "photo"
        case "Video": "film"
        case "Audio", "Music": "waveform"
        case "All Media": "square.grid.2x2"
        default: "folder"
        }
    }
}

private struct MediaCard: View {
    @EnvironmentObject private var store: EditorStore
    let asset: MediaAsset

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.86))

                if let image = store.thumbnail(for: asset) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
            }
            .aspectRatio(4 / 3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(asset.filename)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Text(asset.url.deletingLastPathComponent().lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(store.selectedAssetID == asset.id ? Color.orange : Color.clear, lineWidth: 2)
        }
    }
}
