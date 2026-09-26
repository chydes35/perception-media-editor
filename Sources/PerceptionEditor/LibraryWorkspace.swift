import SwiftUI

struct LibraryWorkspace: View {
    @EnvironmentObject private var store: EditorStore
    @State private var selection: String = "All Media"

    private let columns = [
        GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 14)
    ]

    private var nonPhotos: [MediaAsset] {
        store.project.media.filter { $0.kind != .photo }
    }

    private var items: [MediaAsset] {
        switch selection {
        case "Photos": store.visiblePhotos
        case "Video": store.project.media.filter { $0.kind == .video }
        case "Audio": store.project.media.filter { $0.kind == .audio }
        default: store.filter.isActive ? store.visiblePhotos : store.visiblePhotos + nonPhotos
        }
    }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 190, idealWidth: 220, maxWidth: 260)
            library
                .frame(minWidth: 700, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                heading("PROJECT")
                ForEach(["All Media", "Photos", "Video", "Audio"], id: \.self) { item in
                    row(
                        title: item,
                        symbol: icon(for: item),
                        count: count(for: item),
                        isSelected: selection == item
                    ) { selection = item }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                heading("CULLING")
                ForEach([PhotoFlag.picked, .rejected, .unflagged]) { flag in
                    row(
                        title: flag.title,
                        symbol: symbol(for: flag),
                        count: store.count(of: flag),
                        isSelected: store.filter.flags == [flag]
                    ) {
                        store.filter.flags = store.filter.flags == [flag] ? [] : [flag]
                        selection = "Photos"
                    }
                }
            }

            Spacer()

            Button {
                store.showImportSheet()
            } label: {
                Label("Import from Card…", systemImage: "sdcard")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .tracking(1.2)
            .foregroundStyle(.secondary)
    }

    private func row(
        title: String,
        symbol: String,
        count: Int,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: symbol)
                    .frame(width: 18)
                Text(title)
                Spacer()
                Text("\(count)")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                isSelected ? Color.accentColor.opacity(0.14) : .clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Grid

    private var library: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.project.name)
                        .font(.title2.weight(.semibold))
                    Text(store.originalsFolder.map { "Originals: \($0.path)" }
                        ?? "Reference files stay in their original locations.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text("\(items.count) ITEMS")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(20)

            Divider()
            FilterBar()
            Divider()

            if store.project.media.isEmpty {
                ContentUnavailableView {
                    Label("Your library is empty", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("Import a card to copy and back up a shoot, or add existing files in place.")
                } actions: {
                    Button("Import from Card…") { store.showImportSheet() }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                    Button("Add Files in Place…") { store.importMedia() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                ContentUnavailableView {
                    Label("Nothing matches", systemImage: "line.3.horizontal.decrease.circle")
                } actions: {
                    Button("Clear Filter") { store.filter = LibraryFilter() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(items) { asset in
                            MediaCard(asset: asset)
                                .onTapGesture(count: 2) { open(asset) }
                                .onTapGesture { click(asset) }
                                .contextMenu { contextMenu(for: asset) }
                        }
                    }
                    .padding(20)
                }
            }
        }
    }

    private func click(_ asset: MediaAsset) {
        guard asset.kind == .photo else {
            store.selectVideo(asset)
            return
        }
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.command) {
            store.toggleSelection(asset)
        } else if modifiers.contains(.shift) {
            store.extendSelection(to: asset)
        } else {
            store.select(asset)
        }
    }

    private func open(_ asset: MediaAsset) {
        if asset.kind == .photo {
            store.select(asset)
            store.workspace = .cull
        } else {
            store.selectVideo(asset)
            store.workspace = .video
        }
    }

    /// Right-click acts on the whole selection when the clicked photo is part of it.
    private func targets(for asset: MediaAsset) -> [UUID] {
        store.selectedAssetIDs.contains(asset.id) ? Array(store.selectedAssetIDs) : [asset.id]
    }

    @ViewBuilder
    private func contextMenu(for asset: MediaAsset) -> some View {
        if asset.kind == .photo {
            let ids = targets(for: asset)
            Menu("Flag") {
                ForEach(PhotoFlag.allCases) { flag in
                    Button(flag.title) { store.setFlag(flag, for: ids) }
                }
            }
            Menu("Rating") {
                ForEach(0 ... 5, id: \.self) { rating in
                    Button(rating == 0 ? "None" : String(repeating: "★", count: rating)) {
                        store.setRating(rating, for: ids)
                    }
                }
            }
            Menu("Color Label") {
                Button("None") { store.setLabel(nil, for: ids) }
                ForEach(ColorLabel.allCases) { label in
                    Button(label.title) { store.setLabel(label, for: ids) }
                }
            }
            Menu("Apply Preset") {
                ForEach(store.presetCategories, id: \.self) { category in
                    Menu(category) {
                        ForEach(store.presets(in: category)) { preset in
                            Button(preset.name) { store.apply(preset, to: ids) }
                        }
                    }
                }
            }
            Button("Paste Settings") { store.pasteSettings(to: ids) }
                .disabled(store.copiedSettings == nil)
            Divider()
        }
        Button("Relink Media…") { store.relink(asset) }
        if asset.kind == .photo {
            Button("Remove from Project") { store.removeFromProject(targets(for: asset)) }
        }
    }

    private func icon(for item: String) -> String {
        switch item {
        case "Photos": "photo"
        case "Video": "film"
        case "Audio": "waveform"
        case "All Media": "square.grid.2x2"
        default: "folder"
        }
    }

    private func symbol(for flag: PhotoFlag) -> String {
        switch flag {
        case .picked: "flag.fill"
        case .rejected: "xmark.circle"
        case .unflagged: "flag.slash"
        }
    }

    private func count(for item: String) -> Int {
        switch item {
        case "Photos": store.allPhotos.count
        case "Video": store.project.media.filter { $0.kind == .video }.count
        case "Audio": store.project.media.filter { $0.kind == .audio }.count
        case "All Media": store.project.media.count
        default: 0
        }
    }
}

private struct MediaCard: View {
    @EnvironmentObject private var store: EditorStore
    let asset: MediaAsset

    private var isSelected: Bool {
        store.selectedAssetIDs.contains(asset.id) || store.selectedAssetID == asset.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.86))

                if let image = store.thumbnail(for: asset) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .opacity(asset.flag == .rejected ? 0.4 : 1)
                } else {
                    Image(systemName: asset.kind == .video ? "film" : "waveform")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }

                VStack {
                    HStack(alignment: .top) {
                        if asset.kind == .photo {
                            PhotoBadges(asset: asset)
                        }
                        Spacer()
                        if store.isMissing(asset) {
                            Label("Missing", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(Color.red, in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                    Spacer()
                }
                .padding(8)
            }
            .aspectRatio(4 / 3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(asset.filename)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Text(asset.captureDate.map { $0.formatted(date: .abbreviated, time: .shortened) }
                ?? asset.url.deletingLastPathComponent().lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(isSelected ? Color.orange : Color.clear, lineWidth: 2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
