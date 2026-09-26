import SwiftUI

extension ColorLabel {
    var color: Color {
        switch self {
        case .red: .red
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        }
    }
}

// MARK: - Shared pieces

/// Flag, stars, and color label for a photo, sized for a thumbnail corner.
struct PhotoBadges: View {
    let asset: MediaAsset

    var body: some View {
        HStack(spacing: 4) {
            switch asset.flag {
            case .picked:
                Image(systemName: "flag.fill").foregroundStyle(.green)
            case .rejected:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case .unflagged:
                EmptyView()
            }
            if asset.rating > 0 {
                Text(String(repeating: "★", count: asset.rating))
                    .foregroundStyle(.yellow)
            }
            if let label = asset.colorLabel {
                Circle().fill(label.color).frame(width: 8, height: 8)
            }
        }
        .font(.system(size: 10, weight: .bold))
        .padding(.horizontal, asset.flag == .unflagged && asset.rating == 0 && asset.colorLabel == nil ? 0 : 5)
        .padding(.vertical, 2)
        .background(.black.opacity(0.6), in: Capsule())
        .opacity(asset.flag == .unflagged && asset.rating == 0 && asset.colorLabel == nil ? 0 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        var parts: [String] = []
        if asset.flag != .unflagged { parts.append(asset.flag.title) }
        if asset.rating > 0 { parts.append("\(asset.rating) stars") }
        if let label = asset.colorLabel { parts.append(label.title + " label") }
        return parts.joined(separator: ", ")
    }
}

struct RatingStars: View {
    let rating: Int
    let onSet: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1 ... 5, id: \.self) { star in
                Button {
                    onSet(star == rating ? 0 : star)
                } label: {
                    Image(systemName: star <= rating ? "star.fill" : "star")
                        .foregroundStyle(star <= rating ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help("\(star) star\(star == 1 ? "" : "s") (\(star))")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Rating")
        .accessibilityValue("\(rating) of 5")
    }
}

struct LabelDots: View {
    let selected: Set<ColorLabel>
    let onTap: (ColorLabel) -> Void

    var body: some View {
        HStack(spacing: 5) {
            ForEach(ColorLabel.allCases) { label in
                Button {
                    onTap(label)
                } label: {
                    Circle()
                        .fill(label.color)
                        .frame(width: 13, height: 13)
                        .overlay {
                            Circle().stroke(Color.primary.opacity(selected.contains(label) ? 0.9 : 0), lineWidth: 2)
                        }
                }
                .buttonStyle(.plain)
                .help(label.title)
                .accessibilityLabel(label.title)
                .accessibilityAddTraits(selected.contains(label) ? .isSelected : [])
            }
        }
    }
}

/// Filters for the library, culling view, and filmstrips.
struct FilterBar: View {
    @EnvironmentObject private var store: EditorStore

    private var flagSelection: Binding<PhotoFlag?> {
        Binding(
            get: { store.filter.flags.count == 1 ? store.filter.flags.first : nil },
            set: { store.filter.flags = $0.map { [$0] } ?? [] }
        )
    }

    var body: some View {
        HStack(spacing: 16) {
            Picker("Flag", selection: flagSelection) {
                Text("All").tag(PhotoFlag?.none)
                Text("Picked").tag(PhotoFlag?.some(.picked))
                Text("Rejected").tag(PhotoFlag?.some(.rejected))
                Text("Unflagged").tag(PhotoFlag?.some(.unflagged))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)

            HStack(spacing: 3) {
                Text("MIN")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                ForEach(1 ... 5, id: \.self) { star in
                    Button {
                        store.filter.minimumRating = store.filter.minimumRating == star ? 0 : star
                    } label: {
                        Image(systemName: star <= store.filter.minimumRating ? "star.fill" : "star")
                            .foregroundStyle(star <= store.filter.minimumRating ? Color.yellow : Color.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Show \(star) star\(star == 1 ? "" : "s") and above")
                }
            }

            LabelDots(selected: store.filter.colorLabels) { label in
                if store.filter.colorLabels.contains(label) {
                    store.filter.colorLabels.remove(label)
                } else {
                    store.filter.colorLabels.insert(label)
                }
            }

            if store.filter.isActive {
                Button("Clear Filter") { store.filter = LibraryFilter() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }

            Spacer()

            Text("\(store.visiblePhotos.count) of \(store.allPhotos.count) PHOTOS")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - Cull workspace

struct CullWorkspace: View {
    @EnvironmentObject private var store: EditorStore

    var body: some View {
        VStack(spacing: 0) {
            FilterBar()
            Divider()
            stage
            Divider()
            controlBar
            Divider()
            CullFilmstrip()
                .frame(height: 112)
        }
        .onAppear { store.refreshLoupe() }
    }

    @ViewBuilder
    private var stage: some View {
        ZStack {
            Color.black

            if store.allPhotos.isEmpty {
                ContentUnavailableView {
                    Label("No photos to cull", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("Import a card to copy, back up, and start culling.")
                } actions: {
                    Button("Import from Card…") { store.showImportSheet() }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                }
                .foregroundStyle(.white, .white.opacity(0.62))
            } else if store.visiblePhotos.isEmpty {
                ContentUnavailableView {
                    Label("No photos match the filter", systemImage: "line.3.horizontal.decrease.circle")
                } actions: {
                    Button("Clear Filter") { store.filter = LibraryFilter() }
                }
                .foregroundStyle(.white, .white.opacity(0.62))
            } else if let pinnedID = store.compareAssetID,
                      let pinned = store.project.media.first(where: { $0.id == pinnedID }),
                      let candidate = store.selectedAsset {
                HStack(spacing: 2) {
                    CullPane(title: "SELECT", asset: pinned, image: store.compareImage, showsPosition: false)
                    CullPane(title: "CANDIDATE", asset: candidate, image: store.loupeImage, showsPosition: true)
                }
            } else if let asset = store.selectedAsset {
                CullPane(title: nil, asset: asset, image: store.loupeImage, showsPosition: true)
            } else {
                Text("Select a photo")
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var controlBar: some View {
        HStack(spacing: 18) {
            let asset = store.selectedAsset

            RatingStars(rating: asset?.rating ?? 0) { store.setRating($0) }

            HStack(spacing: 6) {
                flagButton(.picked, symbol: "flag.fill", tint: .green, key: "P")
                flagButton(.rejected, symbol: "xmark.circle.fill", tint: .red, key: "X")
                flagButton(.unflagged, symbol: "flag.slash", tint: .secondary, key: "U")
            }

            LabelDots(selected: asset?.colorLabel.map { [$0] } ?? []) { store.toggleLabel($0) }

            Spacer()

            Toggle("Auto-advance", isOn: $store.autoAdvance)
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("Move to the next photo after picking or rejecting")

            Button {
                store.toggleCompare()
            } label: {
                Label(store.compareAssetID == nil ? "Compare" : "Exit Compare", systemImage: "square.split.2x1")
            }
            .help("Pin this photo and compare others against it (C)")
            .disabled(asset == nil)

            Button {
                store.deleteRejected()
            } label: {
                Label("Delete Rejected…", systemImage: "trash")
            }
            .disabled(store.rejectedCount == 0)
            .help("Move rejected originals to the Trash")

            Button {
                store.perform(.toggleFullScreen)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .help("Full screen (F)")

            Button {
                store.workspace = .photo
            } label: {
                Label("Develop", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(asset == nil)
            .help("Open in Develop (D)")
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func flagButton(_ flag: PhotoFlag, symbol: String, tint: Color, key: String) -> some View {
        let isCurrent = store.selectedAsset?.flag == flag
        return Button {
            store.perform(.flag(flag))
        } label: {
            Image(systemName: symbol)
                .foregroundStyle(isCurrent ? tint : Color.secondary)
                .frame(width: 22, height: 22)
                .background(isCurrent ? tint.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.borderless)
        .help("\(flag.title) (\(key))")
        .accessibilityLabel(flag.title)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

/// One photo in the loupe, with its details overlaid.
private struct CullPane: View {
    @EnvironmentObject private var store: EditorStore
    let title: String?
    let asset: MediaAsset
    let image: NSImage?
    let showsPosition: Bool

    var body: some View {
        ZStack {
            Color.black
            if store.isMissing(asset) {
                ContentUnavailableView(
                    "Original is missing",
                    systemImage: "exclamationmark.triangle",
                    description: Text("\(asset.filename) is not at its saved location. Use Relink from the Library.")
                )
                .foregroundStyle(.white, .white.opacity(0.62))
            } else if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(6)
            } else {
                ProgressView().controlSize(.large)
            }
        }
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 3) {
                if let title {
                    Text(title)
                        .font(.system(size: 9, weight: .heavy))
                        .tracking(1.4)
                        .foregroundStyle(.orange)
                }
                Text(asset.filename)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                Text(details)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .foregroundStyle(.white)
            .padding(8)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
            .padding(10)
        }
        .overlay(alignment: .topTrailing) {
            PhotoBadges(asset: asset).padding(14)
        }
        .clipped()
    }

    private var details: String {
        var parts: [String] = []
        if showsPosition, let position = store.selectedPosition {
            parts.append("\(position) of \(store.visiblePhotos.count)")
        }
        if let width = asset.pixelWidth, let height = asset.pixelHeight {
            parts.append("\(width)×\(height)")
        }
        if let date = asset.captureDate {
            parts.append(date.formatted(date: .abbreviated, time: .standard))
        }
        return parts.joined(separator: "  ·  ")
    }
}

private struct CullFilmstrip: View {
    @EnvironmentObject private var store: EditorStore

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    ForEach(store.visiblePhotos) { asset in
                        cell(for: asset)
                            .id(asset.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .onChange(of: store.selectedAssetID) { _, id in
                if let id { proxy.scrollTo(id, anchor: .center) }
            }
            .onAppear {
                if let id = store.selectedAssetID { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func cell(for asset: MediaAsset) -> some View {
        let isSelected = asset.id == store.selectedAssetID
        return Button {
            store.select(asset)
        } label: {
            ZStack {
                Color.gray.opacity(0.25)
                if let image = store.thumbnail(for: asset) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .frame(width: 108, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .opacity(asset.flag == .rejected ? 0.4 : 1)
            .overlay(alignment: .bottomLeading) {
                PhotoBadges(asset: asset).padding(3)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(isSelected ? Color.orange : .clear, lineWidth: 3)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(asset.filename)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
