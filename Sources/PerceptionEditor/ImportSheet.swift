import SwiftUI

struct ImportSheet: View {
    @EnvironmentObject private var store: EditorStore

    @State private var source: URL?
    @State private var sourceSummary: String?
    @State private var cards: [URL] = IngestService.detectedCards()
    @State private var addToCurrent = false
    @State private var shootName = ""
    @State private var shootDate = Date()
    @State private var shootsRoot = ImportSettings.shootsRoot
    @State private var backupEnabled = ImportSettings.backupEnabled
    @State private var backupRoot = ImportSettings.backupRoot

    private var canAddToCurrent: Bool { store.projectURL != nil }

    private var effectiveBackupRoot: URL? { backupEnabled ? backupRoot : nil }

    private var canStart: Bool {
        guard source != nil else { return false }
        return addToCurrent ? canAddToCurrent : !shootName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Import Photos")
                .font(.title2.weight(.semibold))

            switch store.ingest {
            case .idle:
                form
            case .scanning:
                progressBlock(title: "Looking for photos…", fraction: nil, detail: nil)
            case .copying(let progress):
                copyingBlock(progress)
            case .finished(let summary):
                summaryBlock(summary)
            case .failed(let message):
                failureBlock(message)
            }
        }
        .padding(24)
        .frame(width: 560)
        .interactiveDismissDisabled(store.ingest.isRunning)
        .onAppear {
            cards = IngestService.detectedCards()
            if source == nil, cards.count == 1 { choose(cards[0]) }
            addToCurrent = false
        }
    }

    // MARK: - Form

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("From") {
                VStack(alignment: .leading, spacing: 8) {
                    if cards.isEmpty {
                        Text("No camera card detected. Insert one, or choose a folder.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(cards, id: \.self) { card in
                        Button {
                            choose(card)
                        } label: {
                            Label(card.lastPathComponent, systemImage: source == card ? "sdcard.fill" : "sdcard")
                        }
                        .buttonStyle(.bordered)
                    }
                    HStack {
                        Button("Choose Folder…") { chooseFolder() }
                        if let source {
                            Text(source.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    if let sourceSummary {
                        Text(sourceSummary).font(.caption.weight(.medium))
                    }
                    Text("The card is only read. Nothing is deleted from it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            GroupBox("To") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Destination", selection: $addToCurrent) {
                        Text("New shoot").tag(false)
                        Text("Add to current shoot").tag(true).disabled(!canAddToCurrent)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    if addToCurrent {
                        Text("Photos are copied into \(store.originalsFolder?.path ?? "the current shoot").")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        TextField("Shoot name (e.g. Smith Wedding)", text: $shootName)
                        DatePicker("Shoot date", selection: $shootDate, displayedComponents: .date)
                        HStack {
                            Text("Shoots folder")
                            Text(shootsRoot.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button("Change…") { chooseShootsRoot() }
                        }
                        Text("Copies go to “\(ShootLayout.folderName(date: shootDate, name: shootName.isEmpty ? "Name" : shootName))/Originals”. Camera filenames are kept.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            GroupBox("Backup") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Also copy to a backup drive", isOn: $backupEnabled)
                    if backupEnabled {
                        HStack {
                            Text(backupRoot?.path ?? "No backup folder chosen")
                                .font(.caption)
                                .foregroundStyle(backupRoot == nil ? .orange : .secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button(backupRoot == nil ? "Choose…" : "Change…") { chooseBackupRoot() }
                        }
                        Text("If the backup drive isn’t connected, the import still runs and tells you the backup was skipped.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            HStack {
                Spacer()
                Button("Cancel") { store.isShowingImportSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("Import") { start() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(!canStart)
            }
        }
    }

    // MARK: - Progress and results

    private func copyingBlock(_ progress: IngestProgress) -> some View {
        let title = progress.phase == .copying ? "Copying to the shoot" : "Copying to the backup drive"
        let detail = "\(progress.currentFilename)  ·  \(min(progress.completedFiles + 1, progress.totalFiles)) of \(progress.totalFiles)"
        return progressBlock(title: title, fraction: progress.fraction, detail: detail)
    }

    private func progressBlock(title: String, fraction: Double?, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            if let fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Text("Every file is checked against the original after it is copied.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Stop After This File") { store.cancelIngest() }
            }
        }
    }

    private func summaryBlock(_ summary: IngestSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                summary.wasCancelled ? "Import stopped" : "Import complete",
                systemImage: summary.wasCancelled ? "pause.circle.fill" : "checkmark.circle.fill"
            )
            .font(.headline)
            .foregroundStyle(summary.wasCancelled ? .orange : .green)

            VStack(alignment: .leading, spacing: 4) {
                Text("\(summary.copied) copied and verified")
                if summary.alreadyPresent > 0 {
                    Text("\(summary.alreadyPresent) already in this shoot (skipped)")
                }
                Text(backupText(summary.backup))
                    .foregroundStyle(backupIsProblem(summary.backup) ? .orange : .primary)
            }

            if !summary.failures.isEmpty {
                GroupBox("\(summary.failures.count) could not be copied") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(summary.failures.enumerated()), id: \.offset) { _, failure in
                                Text("\(failure.filename): \(failure.reason)").font(.caption)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 100)
                }
                Text("These are still on the card. Do not erase the card until they are copied.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }

            HStack {
                Button("Show in Finder") { NSWorkspace.shared.open(summary.shootFolder) }
                Spacer()
                Button("Close") { store.isShowingImportSheet = false; store.ingest = .idle }
                Button("Start Culling") { store.beginCullingAfterImport() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
            }
        }
    }

    private func failureBlock(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Import failed", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.red)
            Text(message)
            HStack {
                Spacer()
                Button("Back") { store.ingest = .idle }
                Button("Close") { store.isShowingImportSheet = false; store.ingest = .idle }
            }
        }
    }

    private func backupText(_ outcome: BackupOutcome) -> String {
        switch outcome {
        case .notRequested: "No backup made"
        case .unavailable(let reason): "Backup skipped: \(reason)"
        case .completed(let copied, let present):
            present > 0 ? "Backup complete (\(copied) copied, \(present) already there)" : "Backup complete (\(copied) copied)"
        case .partial(let copied, let failed): "Backup incomplete: \(copied) copied, \(failed) failed"
        }
    }

    private func backupIsProblem(_ outcome: BackupOutcome) -> Bool {
        switch outcome {
        case .unavailable, .partial: true
        default: false
        }
    }

    // MARK: - Actions

    private func choose(_ url: URL) {
        source = url
        sourceSummary = "Counting files…"
        Task {
            let files = await Task.detached { IngestService.scan(url) }.value
            guard source == url else { return }
            let bytes = files.reduce(Int64(0)) { $0 + $1.size }
            let photos = files.filter { $0.kind == .photo }.count
            let videos = files.filter { $0.kind == .video }.count
            var parts = ["\(photos) photo\(photos == 1 ? "" : "s")"]
            if videos > 0 { parts.append("\(videos) video\(videos == 1 ? "" : "s")") }
            sourceSummary = files.isEmpty
                ? "No photos or videos found here."
                : parts.joined(separator: ", ") + " · " + ByteCountFormatter().string(fromByteCount: bytes)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a card or folder to import"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { choose(url) }
    }

    private func chooseShootsRoot() {
        if let url = chooseDestinationFolder(title: "Choose where shoots are stored") {
            shootsRoot = url
            ImportSettings.shootsRoot = url
        }
    }

    private func chooseBackupRoot() {
        if let url = chooseDestinationFolder(title: "Choose the backup folder") {
            backupRoot = url
            ImportSettings.backupRoot = url
        }
    }

    private func chooseDestinationFolder(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func start() {
        guard let source else { return }
        ImportSettings.backupEnabled = backupEnabled
        let destination: ImportRequest.Destination = addToCurrent
            ? .currentShoot
            : .newShoot(name: shootName, date: shootDate, root: shootsRoot)
        store.startIngest(ImportRequest(source: source, destination: destination, backupRoot: effectiveBackupRoot))
    }
}
