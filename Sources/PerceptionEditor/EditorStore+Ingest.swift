import AppKit

/// Where a shoot's files go: `<Shoots>/<yyyy-MM-dd Name>/{Name.pmedit, Originals/}`,
/// with an optional mirror at `<Backup>/<yyyy-MM-dd Name>/Originals/`.
enum ShootLayout {
    static func sanitized(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled Shoot" : cleaned
    }

    static func folderName(date: Date, name: String, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        return "\(day) \(sanitized(name))"
    }

    static func originals(in shootFolder: URL) -> URL {
        shootFolder.appendingPathComponent("Originals", isDirectory: true)
    }

    static func projectURL(in shootFolder: URL, name: String) -> URL {
        shootFolder
            .appendingPathComponent(sanitized(name))
            .appendingPathExtension(ProjectDocument.fileExtension)
    }

    static func backupOriginals(backupRoot: URL, shootFolderName: String) -> URL {
        originals(in: backupRoot.appendingPathComponent(shootFolderName, isDirectory: true))
    }
}

/// Import locations remembered between launches.
enum ImportSettings {
    private static let shootsKey = "perceptionEditor.shootsRoot"
    private static let backupKey = "perceptionEditor.backupRoot"
    private static let backupEnabledKey = "perceptionEditor.backupEnabled"

    /// The external SSD when it is connected, otherwise the Pictures folder.
    static var shootsRoot: URL {
        get {
            if let path = UserDefaults.standard.string(forKey: shootsKey) {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            let ssd = URL(fileURLWithPath: "/Volumes/ExSSD1/Shoots", isDirectory: true)
            if FileManager.default.fileExists(atPath: "/Volumes/ExSSD1") { return ssd }
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Pictures/Shoots", isDirectory: true)
        }
        set { UserDefaults.standard.set(newValue.path, forKey: shootsKey) }
    }

    static var backupRoot: URL? {
        get { UserDefaults.standard.string(forKey: backupKey).map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set { UserDefaults.standard.set(newValue?.path, forKey: backupKey) }
    }

    static var backupEnabled: Bool {
        get { UserDefaults.standard.object(forKey: backupEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: backupEnabledKey) }
    }
}

struct ImportRequest {
    enum Destination {
        case newShoot(name: String, date: Date, root: URL)
        case currentShoot
    }

    var source: URL
    var destination: Destination
    /// Nil when backup is off or no backup folder was chosen.
    var backupRoot: URL?
}

struct IngestSummary: Equatable {
    var copied: Int
    var alreadyPresent: Int
    var failures: [IngestFailure]
    var backup: BackupOutcome
    var wasCancelled: Bool
    var shootFolder: URL
}

enum IngestState: Equatable {
    case idle
    case scanning
    case copying(IngestProgress)
    case finished(IngestSummary)
    case failed(String)

    var isRunning: Bool {
        switch self {
        case .scanning, .copying: true
        default: false
        }
    }
}

extension EditorStore {
    func showImportSheet() {
        if !ingest.isRunning { ingest = .idle }
        isShowingImportSheet = true
    }

    func cancelIngest() {
        ingestTask?.cancel()
        ingestScanTask?.cancel()
        ingestWorker?.cancel()
    }

    /// Project replacement invalidates callbacks even when the same saved project is reopened.
    func invalidateIngest() {
        cancelIngest()
        if let ingestWorker { retiringIngestWorker = ingestWorker }
        ingestOperationID = nil
        ingestTask = nil
        ingestScanTask = nil
        ingestWorker = nil
        if ingest.isRunning { isShowingImportSheet = false }
        ingest = .idle
    }

    func acceptsIngest(_ operation: UUID, generation: UUID) -> Bool {
        ingestOperationID == operation && projectGeneration == generation
    }

    func startIngest(_ request: ImportRequest) {
        guard !ingest.isRunning else { return }

        let shootFolder: URL
        let shootFolderName: String
        switch request.destination {
        case .currentShoot:
            guard let projectURL else {
                ingest = .failed("Create a shoot first, then add more cards to it.")
                return
            }
            shootFolder = projectURL.deletingLastPathComponent()
            shootFolderName = shootFolder.lastPathComponent

        case .newShoot(let name, let date, let root):
            guard confirmDiscardingUnsavedChanges() else { return }
            shootFolderName = ShootLayout.folderName(date: date, name: name)
            shootFolder = root.appendingPathComponent(shootFolderName, isDirectory: true)
            if let problem = IngestService.volumeProblem(for: shootFolder) {
                ingest = .failed(problem)
                return
            }
            do {
                try FileManager.default.createDirectory(at: shootFolder, withIntermediateDirectories: true)
                try openOrCreateShoot(named: ShootLayout.sanitized(name), in: shootFolder)
            } catch {
                ingest = .failed(error.localizedDescription)
                return
            }
        }

        ingest = .scanning
        let source = request.source
        let originals = ShootLayout.originals(in: shootFolder)
        let backupOriginals = request.backupRoot.map {
            ShootLayout.backupOriginals(backupRoot: $0, shootFolderName: shootFolderName)
        }
        let operation = UUID()
        let generation = projectGeneration
        let scanner = ingestScanner
        ingestOperationID = operation

        ingestTask = Task { [weak self] in
            guard let self else { return }
            guard acceptsIngest(operation, generation: generation) else { return }
            if Task.isCancelled {
                completeIngest(IngestResult(wasCancelled: true), shootFolder: shootFolder)
                return
            }
            let scan = Task.detached { scanner(source) }
            ingestScanTask = scan
            let files = await scan.value
            guard acceptsIngest(operation, generation: generation) else { return }
            ingestScanTask = nil
            if Task.isCancelled {
                completeIngest(IngestResult(wasCancelled: true), shootFolder: shootFolder)
                return
            }
            guard !files.isEmpty else {
                ingest = .failed("No photos or videos were found in \(source.lastPathComponent).")
                clearIngestOperation()
                return
            }

            // A replacement import must not remove or reuse a cancelled worker's partials
            // before that worker has closed its file handles and finished cleaning up.
            if let retiring = retiringIngestWorker {
                _ = await retiring.value
                guard acceptsIngest(operation, generation: generation) else { return }
                retiringIngestWorker = nil
                if Task.isCancelled {
                    completeIngest(IngestResult(wasCancelled: true), shootFolder: shootFolder)
                    return
                }
            }

            let worker = Task.detached(priority: .userInitiated) { () -> Result<IngestResult, Error> in
                Result {
                    try IngestService.ingest(
                        files: files,
                        originals: originals,
                        backupOriginals: backupOriginals,
                        onFile: { file in
                            Task { @MainActor in
                                guard self.acceptsIngest(operation, generation: generation) else { return }
                                self.addIngestedFile(file)
                            }
                        },
                        progress: { progress in
                            Task { @MainActor in
                                if self.acceptsIngest(operation, generation: generation), self.ingest.isRunning {
                                    self.ingest = .copying(progress)
                                }
                            }
                        }
                    )
                }
            }
            ingestWorker = worker
            let outcome = await worker.value
            guard acceptsIngest(operation, generation: generation) else { return }
            ingestWorker = nil

            switch outcome {
            case .failure(let error):
                ingest = .failed(error.localizedDescription)
                clearIngestOperation()
            case .success(var result):
                result.wasCancelled = result.wasCancelled || Task.isCancelled
                completeIngest(result, shootFolder: shootFolder)
            }
        }
    }

    /// Opens the shoot's project if it already exists (adding another card to it), or starts a
    /// new one saved into the shoot folder so autosave is on from the first photo.
    private func openOrCreateShoot(named name: String, in shootFolder: URL) throws {
        let projectFile = ShootLayout.projectURL(in: shootFolder, name: name)
        if FileManager.default.fileExists(atPath: projectFile.path) {
            try loadProject(from: projectFile)
        } else {
            resetToEmptyProject(named: name)
            guard saveProject(to: projectFile, announce: false) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [
                    NSLocalizedDescriptionKey: projectSaveError ?? "The shoot project could not be saved."
                ])
            }
        }
    }

    func addIngestedFile(_ file: IngestedFile) {
        guard !project.media.contains(where: { $0.url == file.destinationURL }) else { return }

        let asset = MediaAsset(
            url: file.destinationURL,
            kind: file.kind,
            captureDate: file.metadata?.captureDate,
            pixelWidth: file.metadata?.width,
            pixelHeight: file.metadata?.height
        )
        project.media.append(asset)

        switch file.kind {
        case .photo:
            project.adjustmentsByAssetID[asset.id] = .neutral
        case .video, .audio:
            let assetID = asset.id
            let generation = projectGeneration
            Task {
                let metadata = await VideoMediaService.shared.metadata(for: file.destinationURL)
                guard projectGeneration == generation else { return }
                guard let index = project.media.firstIndex(where: { $0.id == assetID }) else { return }
                project.media[index].apply(metadata)
                proxyStore.enqueue([project.media[index]])
            }
        }
    }

    private func clearIngestOperation() {
        ingestOperationID = nil
        ingestTask = nil
        ingestScanTask = nil
        ingestWorker = nil
    }

    private func completeIngest(_ result: IngestResult, shootFolder: URL) {
        // onFile callbacks are independently queued on the main actor. Reconcile the complete
        // result first so the final save includes every verified file, regardless of ordering.
        for file in result.files { addIngestedFile(file) }
        finishIngest(result, shootFolder: shootFolder)
        clearIngestOperation()
    }

    private func finishIngest(_ result: IngestResult, shootFolder: URL) {
        ingest = .finished(IngestSummary(
            copied: result.copiedCount,
            alreadyPresent: result.alreadyPresentCount,
            failures: result.failures,
            backup: result.backup,
            wasCancelled: result.wasCancelled,
            shootFolder: shootFolder
        ))
        statusMessage = "Imported \(result.files.count) file\(result.files.count == 1 ? "" : "s")"

        filter = LibraryFilter()
        if selectedAsset == nil, let first = allPhotos.first {
            select(first)
        }
        autosaveIfNeeded()
    }

    /// Leaves the import sheet and starts culling the photos that were just brought in.
    func beginCullingAfterImport() {
        isShowingImportSheet = false
        ingest = .idle
        if let first = allPhotos.first {
            select(first)
        }
        workspace = .cull
    }
}
