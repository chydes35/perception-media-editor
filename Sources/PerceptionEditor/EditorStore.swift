import AppKit
@preconcurrency import AVFoundation
import Combine
import Dispatch
import CoreImage
import UniformTypeIdentifiers

@MainActor
final class EditorStore: ObservableObject {
    @Published var project = EditorProject.starter
    @Published var workspace: Workspace = .library {
        didSet {
            workspaceChangeTask?.cancel()
            workspaceChangeTask = nil
            workspaceDidChange()
        }
    }
    private(set) var workspaceChangeTask: Task<Void, Never>?
    @Published var selectedAssetID: UUID? {
        didSet { if oldValue != selectedAssetID { cancelAutoAdjustment() } }
    }
    @Published var selectedAssetIDs: Set<UUID> = []
    @Published var filter = LibraryFilter() {
        didSet { filterDidChange() }
    }
    @Published var compareAssetID: UUID?
    @Published var loupeImage: NSImage?
    @Published var compareImage: NSImage?
    @Published var autoAdvance = UserDefaults.standard.bool(forKey: "perceptionEditor.autoAdvance") {
        didSet { UserDefaults.standard.set(autoAdvance, forKey: "perceptionEditor.autoAdvance") }
    }
    @Published var isShowingImportSheet = false
    @Published var ingest = IngestState.idle
    /// RAW engine defaults for the selected photo; nil when it is not a RAW file.
    @Published var rawInfo: RawInfo?
    @Published var isPickingWhiteBalance = false
    @Published var isSamplingWhiteBalance = false
    var whiteBalanceRequestID = UUID()
    @Published var isRenderingPreview = false
    var autoAdjustmentTask: Task<Void, Never>?
    let autoAdjustmentAnalyzer: (@Sendable (URL, PhotoAdjustments) async throws -> AutoAdjustmentSuggestion)?
    @Published var maskTool: MaskTool = .none
    @Published var selectedMaskID: UUID?
    @Published var showMaskOverlay = false
    /// True while a mask is being dragged or painted, so its area shows without the toggle.
    @Published var isMaskInteracting = false
    @Published var maskOverlay: NSImage?
    @Published var isAnalyzingSubjects = false
    @Published var isPickingSubject = false
    @Published var subjectAnalysis: SubjectAnalysis?
    @Published var subjectSelectionOverlay: NSImage?
    @Published var highlightedSubjectID: Int?
    var subjectRequestID = UUID()
    var subjectOverlayRequestID = UUID()
    var subjectOverlayTask: Task<Void, Never>?
    /// Zero is the all-subject overview. At most four preview-sized overlays are retained.
    var subjectOverlayCache: [(id: Int, image: NSImage)] = []
    var subjectOverlayAdjustments: PhotoAdjustments?
    let subjectAnalyzer = SubjectAnalysisService()
    @Published var isAnalyzingSky = false
    var skyRequestID = UUID()
    let skyAnalyzer = SkyAnalysisService()
    @Published var isAnalyzingAuto = false
    var autoRequestID = UUID()
    let autoAnalyzer = AutoAdjustmentService()
    @Published var brushSize = 0.06
    @Published var brushFeather = 0.5
    @Published var brushErasing = false
    @Published var retouchTool: RetouchKind?
    @Published var selectedRetouchID: UUID?
    @Published var cloneSource: NormalizedPoint?
    @Published var retouchPickingSource = false
    @Published var retouchSize = 0.035
    @Published var retouchFeather = 0.6
    @Published var retouchOpacity = 1.0
    /// Each photo's edit steps for this session, oldest first. Not saved in the project.
    @Published var history: [UUID: [HistoryEntry]] = [:]
    @Published var copiedSettings: CopiedSettings?
    @Published var copySheetMode: CopySheetMode?
    @Published var isShowingSavePresetSheet = false
    /// A name for the next recorded edit, such as "Preset: Documentary Warm".
    var nextHistoryLabel: String?
    @Published var isZoom100 = false
    @Published var focusImage: CGImage?
    @Published var isLoadingFocus = false
    @Published var selectedVideoAssetID: UUID?
    @Published var selectedTimelineClipID: UUID?
    @Published var videoPlayer: AVPlayer?
    @Published private(set) var isTimelinePlayback = false
    @Published private(set) var isVideoPlaying = false
    @Published private(set) var timelinePlaybackPositionSeconds = 0.0
    @Published private(set) var timelinePlaybackDurationSeconds = 0.0
    static let useProxiesKey = "perceptionEditor.useProxies"
    let proxyStore: ProxyStore
    let proxyDefaults: UserDefaults
    @Published private(set) var timelineUsedProxyCount = 0
    @Published var usesProxiesForPlayback = true {
        didSet {
            proxyDefaults.set(usesProxiesForPlayback, forKey: Self.useProxiesKey)
            refreshPlaybackSources()
        }
    }
    @Published private(set) var timelinePlaybackWarnings: [String] = []
    @Published private(set) var audioWaveforms: [UUID: [Float]] = [:]
    @Published var renderedPreview: NSImage?
    @Published var originalPreview: NSImage?
    @Published var previewMode: PreviewMode = .edited
    @Published var histogram = HistogramData.empty
    @Published var userPresets: [PhotoPreset] = []
    @Published var selectedAgentKind: AgentKind = .projectHealth
    @Published var latestAgentReport: AgentReport?
    @Published var statusMessage = "Ready"
    @Published var lastError: String?
    /// Independent of general status messages, so a later edit cannot hide a failed save.
    @Published var projectSaveError: String?
    @Published private(set) var isEditingCrop = false
    @Published var isExporting = false
    @Published var batchExportState = BatchExportState()
    var batchExportTask: Task<Void, Never>?
    let batchPhotoExporter: BatchPhotoExporter?
    @Published private(set) var thumbnailRevision = 0

    var projectURL: URL?
    var projectGeneration = UUID()
    /// The project as it was last opened or saved; `hasUnsavedChanges` compares against it.
    var lastSavedProject = EditorProject.starter

    let photoRenderer = PhotoRenderer()
    /// Optional boundary-test operation; production previews use the render actor below.
    private let previewRenderOperation: (@Sendable (URL, PhotoAdjustments, UUID?, Bool) async
        -> (RenderedImage?, PhotoPreviewResult?))?
    private let thumbnailRenderer = PhotoRenderer(workingCacheLimit: 0, memoryTargetMB: 32)
    let cullCache = CullPreviewCache()
    /// Full-resolution decodes for the 100% view get their own renderer, so a one-second decode
    /// never holds up slider previews.
    let focusRenderer = PhotoRenderer(workingCacheLimit: 0, memoryTargetMB: 128)
    var rawInfoAssetID: UUID?
    var zoomCenter = CGPoint(x: 0.5, y: 0.5)
    var focusFullSize = CGSize.zero
    var focusViewportPixels = CGSize.zero
    var focusTask: Task<Void, Never>?
    var needsAnotherFocus = false
    private var memoryPressureSource: (any DispatchSourceMemoryPressure)?
    private var cancellables: Set<AnyCancellable> = []
    var ingestWorker: Task<Result<IngestResult, Error>, Never>?
    var retiringIngestWorker: Task<Result<IngestResult, Error>, Never>?
    var ingestTask: Task<Void, Never>?
    var ingestScanTask: Task<[SourceFile], Never>?
    var ingestOperationID: UUID?
    let ingestScanner: @Sendable (URL) -> [SourceFile]
    private(set) var previewTask: Task<Void, Never>?
    private var needsAnotherPreviewRender = false
    private var originalPreviewAssetID: UUID?
    private var pendingPhotoThumbnails: Set<UUID> = []
    let document = ProjectDocument()
    let userPresetRepository: UserPresetRepository
    let thumbnailCache = ThumbnailCache()
    private let videoMediaService = VideoMediaService.shared
    private let audioWaveformService = AudioWaveformService.shared
    private let timelineCompositionService = TimelineCompositionService.shared
    private var pendingVideoThumbnails: Set<UUID> = []
    private var pendingAudioWaveforms: Set<UUID> = []
    private var compositionRebuildTask: Task<Void, Never>?
    private var playbackMonitorTask: Task<Void, Never>?
    private var playbackRequestID = UUID()
    var photoUndoHistory = PhotoUndoHistory()
    var activeAdjustmentSnapshot: [UUID: PhotoAdjustments]?

    init(
        presetRepository: UserPresetRepository = UserPresetRepository(),
        ingestScanner: @escaping @Sendable (URL) -> [SourceFile] = { IngestService.scan($0) },
        autoAdjustmentAnalyzer: (@Sendable (URL, PhotoAdjustments) async throws -> AutoAdjustmentSuggestion)? = nil,
        batchPhotoExporter: BatchPhotoExporter? = nil,
        previewRenderOperation: (@Sendable (URL, PhotoAdjustments, UUID?, Bool) async
            -> (RenderedImage?, PhotoPreviewResult?))? = nil,
        proxyStore: ProxyStore = ProxyStore(),
        proxyDefaults: UserDefaults = TestIsolation.isRunningTests ? TestIsolation.defaults : .standard
    ) {
        self.proxyStore = proxyStore
        self.proxyDefaults = proxyDefaults
        usesProxiesForPlayback = proxyDefaults.object(forKey: Self.useProxiesKey) as? Bool ?? true
        self.ingestScanner = ingestScanner
        self.autoAdjustmentAnalyzer = autoAdjustmentAnalyzer
        self.batchPhotoExporter = batchPhotoExporter
        self.previewRenderOperation = previewRenderOperation
        userPresetRepository = presetRepository
        userPresets = presetRepository.load()
        cullCache.onLoaded = { [weak self] id in self?.cullPreviewLoaded(id) }
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in self?.releaseMemoryUnderPressure() }
        }
        pressure.resume()
        memoryPressureSource = pressure

        // Projects with a file on disk save themselves shortly after every change, so culling
        // and rating work is never lost to a crash or a forgotten ⌘S.
        $project
            .dropFirst()
            .debounce(for: .seconds(1.5), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.autosaveIfNeeded() }
            }
            .store(in: &cancellables)

        proxyStore.onReady = { [weak self] id in self?.proxyBecameReady(id) }
        // Forward only status-case changes; progress ticks would re-render the whole editor.
        proxyStore.$statuses
            .map { $0.mapValues(Self.proxyStatusKind) }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    deinit { memoryPressureSource?.cancel() }

    var presets: [PhotoPreset] {
        PhotoPreset.builtIns + userPresets
    }

    var isShowingOriginal: Bool {
        previewMode == .original
    }

    var hasUnsavedChanges: Bool {
        project != lastSavedProject
    }

    var selectedAsset: MediaAsset? {
        guard let selectedAssetID else { return nil }
        return project.media.first(where: { $0.id == selectedAssetID })
    }

    var selectedVideoAsset: MediaAsset? {
        guard let selectedVideoAssetID else { return nil }
        return project.media.first(where: { $0.id == selectedVideoAssetID })
    }

    var selectedTimelineClip: TimelineClip? {
        guard let selectedTimelineClipID else { return nil }
        return project.timelineClips.first(where: { $0.id == selectedTimelineClipID })
    }

    var videoAssets: [MediaAsset] {
        project.media.filter { $0.kind == .video }
    }

    var timelineDurationSeconds: Double {
        project.timelineClips.map { $0.timelineStartSeconds + $0.durationSeconds }.max() ?? 0
    }

    var selectedAdjustments: PhotoAdjustments {
        get {
            guard let selectedAssetID else { return .neutral }
            return project.adjustmentsByAssetID[selectedAssetID] ?? .neutral
        }
        set {
            guard let selectedAssetID else { return }
            project.adjustmentsByAssetID[selectedAssetID] = newValue
            refreshPreview()
        }
    }

    var canUndoPhotoEdit: Bool { !photoUndoHistory.undo.isEmpty }
    var canRedoPhotoEdit: Bool { !photoUndoHistory.redo.isEmpty }

    var selectedVideoAdjustments: PhotoAdjustments {
        guard let selectedTimelineClipID else { return .neutral }
        return project.videoAdjustmentsByClipID[selectedTimelineClipID] ?? .neutral
    }

    var selectedAudioAdjustments: ClipAudioAdjustments {
        guard let selectedTimelineClipID else { return .neutral }
        return project.audioAdjustmentsByClipID[selectedTimelineClipID] ?? .neutral
    }

    func importMedia() {
        let panel = NSOpenPanel()
        panel.title = "Import Media"
        panel.prompt = "Import"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .rawImage, .movie, .audio]

        guard panel.runModal() == .OK else { return }
        statusMessage = "Importing media…"
        importURLs(panel.urls)
    }

    @discardableResult
    func importURLs(_ urls: [URL]) -> Task<Void, Never> {
        let generation = projectGeneration
        return Task {
            await importURLsAsync(urls, generation: generation)
        }
    }

    private func importURLsAsync(_ urls: [URL], generation: UUID) async {
        guard projectGeneration == generation else { return }
        var importedCount = 0
        var lastImportedKind: MediaKind?

        for url in urls {
            guard let kind = mediaKind(for: url) else { continue }

            switch kind {
            case .photo:
                // Import reads metadata only; pixels are decoded later, on demand and off the main actor.
                guard let size = await Task.detached(operation: { PhotoSourceLoader.dimensions(of: url) }).value else {
                    continue
                }
                guard projectGeneration == generation else { return }
                let asset = MediaAsset(
                    url: url,
                    kind: .photo,
                    pixelWidth: size.width,
                    pixelHeight: size.height
                )
                project.media.append(asset)
                project.adjustmentsByAssetID[asset.id] = .neutral
                selectedAssetID = asset.id
                importedCount += 1
            case .video, .audio:
                let metadata = await videoMediaService.metadata(for: url)
                guard projectGeneration == generation else { return }
                let asset = MediaAsset(
                    url: url,
                    kind: kind,
                    durationSeconds: metadata.durationSeconds,
                    pixelWidth: metadata.pixelWidth,
                    pixelHeight: metadata.pixelHeight
                )
                project.media.append(asset)
                proxyStore.enqueue([asset])
                selectedVideoAssetID = asset.id
                requestAudioWaveform(for: asset)
                if kind == .video {
                    showSourceVideo(asset)
                }
                importedCount += 1
            }

            lastImportedKind = kind
        }

        if importedCount > 0 {
            if lastImportedKind == .photo {
                workspace = .photo
                refreshPreview()
            } else {
                workspace = .video
            }
            statusMessage = "Imported \(importedCount) media item\(importedCount == 1 ? "" : "s")"
        } else {
            lastError = "No supported photos, videos, or audio files were imported."
        }
    }

    func select(_ asset: MediaAsset) {
        guard asset.kind == .photo else {
            selectVideo(asset)
            return
        }
        if selectedAssetID != asset.id {
            endMaskEditing()
            endRetouchEditing()
            cancelWhiteBalancePicking()
            cancelSubjectSelection()
        }
        selectedAssetID = asset.id
        selectedAssetIDs = [asset.id]
        refreshPreview()
        refreshLoupe()
        if isZoom100 { refreshFocus() }
    }

    func selectVideo(_ asset: MediaAsset) {
        guard asset.kind == .video || asset.kind == .audio else { return }
        selectedVideoAssetID = asset.id
        requestAudioWaveform(for: asset)
        showSourceVideo(asset)
        statusMessage = "Selected \(asset.filename)"
    }

    func updateAdjustments(_ update: (inout PhotoAdjustments) -> Void) {
        guard selectedAssetID != nil else { return }
        cancelAutoAdjustment()
        let before = project.adjustmentsByAssetID
        var adjustments = selectedAdjustments
        update(&adjustments)
        selectedAdjustments = adjustments
        if activeAdjustmentSnapshot == nil {
            recordAdjustmentChange(before: before)
        }
    }

    func beginAdjustmentEdit() {
        cancelAutoAdjustment()
        guard activeAdjustmentSnapshot == nil else { return }
        activeAdjustmentSnapshot = project.adjustmentsByAssetID
    }

    func endAdjustmentEdit() {
        guard let snapshot = activeAdjustmentSnapshot else { return }
        activeAdjustmentSnapshot = nil
        recordAdjustmentChange(before: snapshot)
    }

    func cancelAdjustmentEdit() {
        guard let snapshot = activeAdjustmentSnapshot else { return }
        activeAdjustmentSnapshot = nil
        project.adjustmentsByAssetID = snapshot
        refreshPreview()
    }

    func recordAdjustmentChange(before snapshot: [UUID: PhotoAdjustments]) {
        let label = nextHistoryLabel
        nextHistoryLabel = nil
        guard snapshot != project.adjustmentsByAssetID else { return }
        if !photoUndoHistory.record(before: snapshot, after: project.adjustmentsByAssetID) {
            statusMessage = "Edit applied; too large to keep in Undo."
        }
        appendHistory(before: snapshot, label: label)
    }

    private func clearAdjustmentHistory() {
        history = [:]
        photoUndoHistory.clear()
        activeAdjustmentSnapshot = nil
    }

    func resetAdjustments() {
        updateAdjustments { $0 = .neutral }
        statusMessage = "Adjustments reset"
    }

    func undoPhotoEdit() {
        cancelAutoAdjustment()
        guard let step = photoUndoHistory.undoStep() else { return }
        applyUndoStep(step, restoringBefore: true)
        refreshPreview()
        statusMessage = "Undid photo edit"
    }

    func redoPhotoEdit() {
        cancelAutoAdjustment()
        guard let step = photoUndoHistory.redoStep() else { return }
        applyUndoStep(step, restoringBefore: false)
        refreshPreview()
        statusMessage = "Redid photo edit"
    }

    private func applyUndoStep(_ step: PhotoUndoStep, restoringBefore: Bool) {
        let present = Set(project.media.filter { $0.kind == .photo }.map(\.id))
        for (id, change) in step.changes where present.contains(id) {
            project.adjustmentsByAssetID[id] = restoringBefore ? change.before : change.after
        }
    }

    func updateCropRectFromDisplay(_ rect: CGRect?) {
        updateAdjustments { adjustments in
            guard let rect else {
                adjustments.cropRect = nil
                return
            }

            let clamped = rect.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard clamped.width > 0.01, clamped.height > 0.01 else { return }
            adjustments.cropRect = CropRect(
                x: clamped.minX,
                y: 1 - clamped.maxY,
                width: clamped.width,
                height: clamped.height
            )
        }
    }

    func runSelectedAgent() {
        runAgent(selectedAgentKind)
    }

    func runAgent(_ kind: AgentKind) {
        selectedAgentKind = kind
        statusMessage = "Running \(kind.rawValue)…"
        latestAgentReport = AgentEngine.run(
            kind,
            project: project,
            selectedAssetID: selectedAssetID
        )
        statusMessage = "Completed \(kind.rawValue)"
    }

    func applyLatestAgentChanges() {
        guard let report = latestAgentReport, !report.proposedChanges.isEmpty else { return }

        let before = project.adjustmentsByAssetID
        var applied = 0
        for change in report.proposedChanges where change.kind == .copyPhotoAdjustments {
            guard let sourceAssetID = change.sourceAssetID,
                  let targetAssetID = change.targetAssetID,
                  let sourceAdjustments = project.adjustmentsByAssetID[sourceAssetID]
            else { continue }

            project.adjustmentsByAssetID[targetAssetID] = sourceAdjustments.look(
                keepingGeometryOf: project.adjustmentsByAssetID[targetAssetID] ?? .neutral
            )
            applied += 1
        }

        recordAdjustmentChange(before: before)

        latestAgentReport = AgentReport(
            id: report.id,
            kind: report.kind,
            startedAt: report.startedAt,
            finishedAt: .now,
            summary: "Applied \(applied) proposed project change\(applied == 1 ? "" : "s").",
            findings: report.findings,
            proposedChanges: [],
            limitation: report.limitation
        )
        refreshPreview()
        statusMessage = "Applied \(applied) agent change\(applied == 1 ? "" : "s")"
    }

    func updateSelectedVideoAdjustments(_ update: (inout PhotoAdjustments) -> Void) {
        guard let selectedTimelineClipID else { return }
        var adjustments = selectedVideoAdjustments
        update(&adjustments)
        project.videoAdjustmentsByClipID[selectedTimelineClipID] = adjustments
        rebuildTimelinePlayback()
        statusMessage = "Updated clip color"
    }

    func applyVideoPreset(_ preset: PhotoPreset) {
        guard let selectedTimelineClipID else { return }
        // Video clips take a preset's look groups; white balance and RAW detail belong to RAW photos.
        let groups = preset.effectiveGroups.intersection(AdjustmentGroup.looks).subtracting([.rawDetail, .masks])
        project.videoAdjustmentsByClipID[selectedTimelineClipID] =
            selectedVideoAdjustments.applying(preset.adjustments, groups: groups)
        rebuildTimelinePlayback()
        statusMessage = "Applied \(preset.name) to clip"
    }

    func resetSelectedVideoAdjustments() {
        guard let selectedTimelineClipID else { return }
        project.videoAdjustmentsByClipID.removeValue(forKey: selectedTimelineClipID)
        rebuildTimelinePlayback()
        statusMessage = "Clip color reset"
    }

    func updateSelectedAudioAdjustments(_ update: (inout ClipAudioAdjustments) -> Void) {
        guard let selectedTimelineClipID, let selectedTimelineClip else { return }
        var adjustments = selectedAudioAdjustments
        update(&adjustments)
        adjustments.volume = min(1, max(0, adjustments.volume))
        adjustments.pan = min(1, max(-1, adjustments.pan))
        let maximumFade = max(0, selectedTimelineClip.durationSeconds / 2)
        adjustments.fadeInSeconds = min(maximumFade, max(0, adjustments.fadeInSeconds))
        adjustments.fadeOutSeconds = min(maximumFade, max(0, adjustments.fadeOutSeconds))
        project.audioAdjustmentsByClipID[selectedTimelineClipID] = adjustments
        rebuildTimelinePlayback()
        statusMessage = "Updated clip audio"
    }

    func resetSelectedAudioAdjustments() {
        guard let selectedTimelineClipID else { return }
        project.audioAdjustmentsByClipID.removeValue(forKey: selectedTimelineClipID)
        rebuildTimelinePlayback()
        statusMessage = "Clip audio reset"
    }

    func rotate(clockwise: Bool) {
        updateAdjustments { adjustments in
            let delta = clockwise ? 1 : -1
            adjustments.rotationQuarterTurns = (adjustments.rotationQuarterTurns + delta + 4) % 4
        }
    }

    /// Segmented-picker bindings can be written while SwiftUI updates its native view.
    /// Publish navigation and its dependent state only after that update returns.
    func requestWorkspaceChange(to requested: Workspace) {
        workspaceChangeTask?.cancel()
        workspaceChangeTask = nil
        guard requested != workspace else { return }
        let generation = projectGeneration
        workspaceChangeTask = Task { [weak self] in
            guard !Task.isCancelled, let self, generation == self.projectGeneration else { return }
            self.workspaceChangeTask = nil
            self.workspace = requested
        }
    }

    /// Requests a preview of the selected photo. Rendering runs on `PhotoRenderer`; while a
    /// render is in flight, further requests collapse into one follow-up render with the
    /// latest adjustments, so slider drags never queue up stale work.
    func refreshPreview() {
        if isPickingSubject { previewSubjectCandidate(highlightedSubjectID) }
        if isZoom100 { refreshFocus() }
        // Develop-quality renders (a full RAW decode) only run where they are shown.
        guard workspace == .photo || workspace == .export else { return }
        guard let asset = selectedAsset, asset.kind == .photo else {
            needsAnotherPreviewRender = false
            originalPreviewAssetID = nil
            renderedPreview = nil
            originalPreview = nil
            histogram = .empty
            return
        }

        if originalPreviewAssetID != asset.id {
            // Never show the previous photo's preview under this photo's selection.
            renderedPreview = nil
            originalPreview = nil
            histogram = .empty
        }
        refreshRawInfo(for: asset)

        guard previewTask == nil else {
            PhotoPreviewDiagnostics.record("store coalesced workspace=\(workspace.rawValue)")
            needsAnotherPreviewRender = true
            isRenderingPreview = true
            return
        }
        startPreviewRender(for: asset)
    }

    private func startPreviewRender(for asset: MediaAsset) {
        let url = asset.url
        let assetID = asset.id
        let generation = projectGeneration
        let adjustments = isEditingCrop ? selectedAdjustments.withoutCrop : selectedAdjustments
        let needsOriginal = originalPreviewAssetID != assetID
        let renderer = photoRenderer
        let overlayID = (showMaskOverlay || isMaskInteracting) ? selectedMaskID : nil
        let operation = previewRenderOperation
        let requestID = UUID()
        isRenderingPreview = true
        PhotoPreviewDiagnostics.record("store start request=\(requestID) generation=\(generation) originalNeeded=\(needsOriginal) overlayRequested=\(overlayID != nil)")

        previewTask = Task { [weak self] in
            let original: RenderedImage?
            let result: PhotoPreviewResult?
            if let operation {
                (original, result) = await operation(url, adjustments, overlayID, needsOriginal)
            } else {
                original = needsOriginal && !Task.isCancelled ? await renderer.original(url: url) : nil
                result = !Task.isCancelled
                    ? await renderer.preview(url: url, adjustments: adjustments, overlayMaskID: overlayID) : nil
            }
            self?.finishPreviewRender(
                assetID: assetID,
                sourceURL: url,
                generation: generation,
                requestID: requestID,
                needsOriginal: needsOriginal,
                original: original,
                result: result
            )
        }
    }

    private func finishPreviewRender(
        assetID: UUID,
        sourceURL: URL,
        generation: UUID,
        requestID: UUID,
        needsOriginal: Bool,
        original: RenderedImage?,
        result: PhotoPreviewResult?
    ) {
        previewTask = nil
        isRenderingPreview = false

        if !Task.isCancelled, projectGeneration == generation,
           selectedAssetID == assetID, selectedAsset?.url == sourceURL {
            PhotoPreviewDiagnostics.record("store publish request=\(requestID) original=\(original != nil) edited=\(result != nil) overlay=\(result?.maskOverlay != nil) histogram=\(result?.histogram.hasValues == true)")
            if needsOriginal {
                originalPreview = original.map(Self.nsImage)
                originalPreviewAssetID = assetID
            }
            renderedPreview = result.map { Self.nsImage($0.edited) }
            maskOverlay = result?.maskOverlay.map(Self.nsImage)
            histogram = result?.histogram ?? .empty
        } else {
            PhotoPreviewDiagnostics.record("store discard request=\(requestID) canceled=\(Task.isCancelled) generationMatches=\(projectGeneration == generation) assetMatches=\(selectedAssetID == assetID) sourceMatches=\(selectedAsset?.url == sourceURL)")
        }

        if needsAnotherPreviewRender {
            needsAnotherPreviewRender = false
            refreshPreview()
        }
    }

    private static func nsImage(_ image: RenderedImage) -> NSImage {
        NSImage(
            cgImage: image.cgImage,
            size: NSSize(width: image.cgImage.width, height: image.cgImage.height)
        )
    }

    func setShowingOriginal(_ showing: Bool) {
        previewMode = showing ? .original : .edited
    }

    /// Lightroom's `\` behavior: flip between the original and the edit.
    func toggleBeforeAfter() {
        guard workspace == .photo, selectedAsset != nil else { return }
        previewMode = previewMode == .original ? .edited : .original
    }

    func beginCropEditing() {
        guard selectedAsset != nil, !isEditingCrop else { return }
        cancelAutoAdjustment()
        endMaskEditing()
        endRetouchEditing()
        cancelWhiteBalancePicking()
        cancelSubjectSelection()
        exitZoom100()
        beginAdjustmentEdit()
        isEditingCrop = true
        refreshPreview()
    }

    func applyCropEditing(displayRect: CGRect?) {
        guard isEditingCrop else { return }
        updateCropRectFromDisplay(displayRect)
        endAdjustmentEdit()
        isEditingCrop = false
        refreshPreview()
    }

    func cancelCropEditing() {
        guard isEditingCrop else { return }
        cancelAdjustmentEdit()
        isEditingCrop = false
        refreshPreview()
    }

    /// Asks whether to save before the current project is replaced or the app quits.
    /// Returns `false` when the user cancels or the save does not complete.
    func confirmDiscardingUnsavedChanges() -> Bool {
        guard !ingest.isRunning else {
            lastError = "Stop the current import before replacing the project or quitting."
            return false
        }
        guard hasUnsavedChanges else { return true }

        // A project that already has a file autosaves, so just flush the pending change.
        if projectURL != nil, saveProject() { return true }

        let alert = NSAlert()
        alert.messageText = "Save changes to “\(project.name)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don’t Save")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return saveProject()
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    func newProject() {
        guard confirmDiscardingUnsavedChanges() else { return }
        resetToEmptyProject(named: "Untitled Project")
        statusMessage = "New project"
    }

    /// Replaces the current project with an empty one. Callers confirm unsaved changes first.
    func resetToEmptyProject(named name: String) {
        invalidateIngest()
        invalidateBatchExport()
        projectGeneration = UUID()
        proxyStore.cancelAll()
        proxyStore.retainOnly([])
        projectSaveError = nil
        project = EditorProject(name: name)
        lastSavedProject = project
        projectURL = nil
        filter = LibraryFilter()
        selectedAssetID = nil
        selectedAssetIDs = []
        selectedVideoAssetID = nil
        selectedTimelineClipID = nil
        playbackRequestID = UUID()
        compositionRebuildTask?.cancel()
        replaceVideoPlayer(nil, timelineMode: false)
        timelinePlaybackDurationSeconds = 0
        timelinePlaybackWarnings = []
        pendingVideoThumbnails = []
        audioWaveforms = [:]
        pendingAudioWaveforms = []
        resetPhotoRenderState()
        clearAdjustmentHistory()
        previewMode = .edited
        thumbnailCache.clearMemory()
        workspace = .library
    }

    @discardableResult
    func saveProject(saveAs: Bool = false) -> Bool {
        let destination: URL?

        if !saveAs, let projectURL {
            destination = projectURL
        } else {
            let panel = NSSavePanel()
            panel.title = "Save Perception Media Project"
            panel.nameFieldStringValue = project.name
            panel.allowedContentTypes = [UTType(filenameExtension: ProjectDocument.fileExtension) ?? .json]
            destination = panel.runModal() == .OK ? panel.url : nil
        }

        guard let destination else { return false }

        let saved = saveProject(to: destination)
        if !saved { lastError = projectSaveError }
        return saved
    }

    func openProject() {
        guard confirmDiscardingUnsavedChanges() else { return }

        let panel = NSOpenPanel()
        panel.title = "Open Perception Media Project"
        panel.allowedContentTypes = [UTType(filenameExtension: ProjectDocument.fileExtension) ?? .json]
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try loadProject(from: url)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Loads a project file and resets everything derived from the previous one.
    func loadProject(from url: URL) throws {
        let loaded = try document.load(from: url)
        invalidateIngest()
        invalidateBatchExport()
        projectGeneration = UUID()
        proxyStore.cancelAll()
        proxyStore.retainOnly(Set(loaded.media.map(\.id)))
        projectSaveError = nil
        project = loaded
        lastSavedProject = project
        projectURL = url
        filter = LibraryFilter()
        selectedAssetID = nil
        selectedAssetIDs = []
        selectedVideoAssetID = nil
        selectedTimelineClipID = project.timelineClips.first?.id
        resetPhotoRenderState()
        audioWaveforms = [:]
        pendingAudioWaveforms = []
        clearAdjustmentHistory()
        backfillPhotoDimensions()
        for asset in project.media where asset.kind == .video || asset.kind == .audio {
            requestAudioWaveform(for: asset)
        }
        proxyStore.enqueue(project.media, prioritized: Set(project.timelineClips.map(\.assetID)))
        if let first = allPhotos.first {
            selectedAssetID = first.id
            selectedAssetIDs = [first.id]
        } else if let first = project.media.first {
            selectVideo(first)
        }
        refreshPreview()
        refreshLoupe()
        if !project.timelineClips.isEmpty {
            rebuildTimelinePlayback()
        }
        statusMessage = "Opened \(url.lastPathComponent)"
    }

    func exportSelectedPhoto() {
        guard let asset = selectedAsset, asset.kind == .photo else {
            lastError = "Select a photo before exporting."
            return
        }
        guard !isExporting else { return }
        guard !isMissing(asset) else {
            lastError = "The original file could not be loaded. Relink it from the Photo or Library workspace."
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export Edited Photo"
        panel.allowedContentTypes = [.jpeg, .png]
        panel.nameFieldStringValue = asset.url.deletingPathExtension().lastPathComponent + "_edited.jpg"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let protectedOriginals = project.media.map(\.url)
        do {
            try ExportFileSafety.validate(url, protecting: protectedOriginals)
        } catch {
            lastError = error.localizedDescription
            return
        }
        let type: UTType = url.pathExtension.lowercased() == "png" ? .png : .jpeg
        let adjustments = selectedAdjustments
        // Full-resolution decodes get their own renderer so they neither block previews
        // nor stay cached after the export finishes.
        let exporter = PhotoRenderer(workingCacheLimit: 0, memoryTargetMB: 128)
        isExporting = true
        statusMessage = "Exporting \(url.lastPathComponent)…"

        Task {
            do {
                try await exporter.export(
                    url: asset.url, adjustments: adjustments, to: url, type: type,
                    protectedOriginals: protectedOriginals
                )
                statusMessage = "Exported \(url.lastPathComponent)"
            } catch {
                lastError = error.localizedDescription
                statusMessage = "Export failed"
            }
            isExporting = false
        }
    }

    func thumbnail(for asset: MediaAsset) -> NSImage? {
        let adjustments = asset.kind == .photo ? project.adjustmentsByAssetID[asset.id] ?? .neutral : .neutral
        if let cached = thumbnailCache.image(for: asset, adjustments: adjustments) { return cached }
        if asset.kind == .video {
            if !pendingVideoThumbnails.contains(asset.id) {
                pendingVideoThumbnails.insert(asset.id)
                let generation = projectGeneration
                Task {
                    let image = await videoMediaService.thumbnail(for: asset.url)
                    guard generation == projectGeneration else { return }
                    pendingVideoThumbnails.remove(asset.id)
                    guard let image, project.media.contains(where: { $0.id == asset.id && $0.url == asset.url }) else { return }
                    thumbnailCache.store(image, for: asset, adjustments: .neutral)
                    thumbnailRevision &+= 1
                }
            }
        } else if asset.kind == .photo {
            requestPhotoThumbnail(for: asset, adjustments: adjustments)
        }
        return thumbnailCache.previousImage(for: asset)
    }

    /// Renders one photo thumbnail at a time on a dedicated renderer. If the photo's
    /// adjustments changed while it rendered, the next view update requests a fresh one.
    private func requestPhotoThumbnail(for asset: MediaAsset, adjustments: PhotoAdjustments) {
        guard !pendingPhotoThumbnails.contains(asset.id), !isMissing(asset) else { return }
        pendingPhotoThumbnails.insert(asset.id)
        let renderer = thumbnailRenderer
        let generation = projectGeneration

        Task { [weak self] in
            let rendered = await renderer.thumbnail(url: asset.url, adjustments: adjustments)
            guard let self, generation == projectGeneration else { return }
            pendingPhotoThumbnails.remove(asset.id)
            guard let rendered, project.media.contains(where: { $0.id == asset.id && $0.url == asset.url }) else { return }
            guard (project.adjustmentsByAssetID[asset.id] ?? .neutral) == adjustments else {
                // Request the current edit on the next redraw after discarding this stale render.
                thumbnailRevision &+= 1
                return
            }
            let image = Self.nsImage(rendered)
            thumbnailCache.store(image, for: asset, adjustments: adjustments)
            thumbnailRevision &+= 1
        }
    }

    /// Drops every cached thumbnail for a photo that left the project.
    func photoThumbnailsForget(_ id: UUID) {
        pendingPhotoThumbnails.remove(id)
        thumbnailCache.invalidate(assetID: id)
    }

    /// Called by macOS when shared CPU/GPU memory is under pressure. Visible images remain
    /// available; expendable caches are released on their owning render actors.
    func releaseMemoryUnderPressure() {
        thumbnailCache.clearMemory()
        cullCache.clear()
        BrushMaskCache.shared.clear()
        SubjectMaskRenderer.clearCaches()
        cancelSubjectSelection()
        let renderer = photoRenderer
        let thumbnails = thumbnailRenderer
        let focus = focusRenderer
        Task {
            await renderer.releaseMemoryUnderPressure()
            await thumbnails.clearRenderCaches()
            await focus.clearRenderCaches()
        }
    }

    private func resetPhotoRenderState() {
        workspaceChangeTask?.cancel()
        workspaceChangeTask = nil
        PhotoPreviewDiagnostics.record("store reset pending=\(previewTask != nil)")
        // Keep the worker slot until its completion drains. Starting a new render while
        // the old actor call finishes would queue unbounded work during repeated opens.
        previewTask?.cancel()
        isRenderingPreview = false
        cancelAutoAdjustment()
        endMaskEditing()
        endRetouchEditing()
        cancelWhiteBalancePicking()
        cancelSubjectSelection()
        SubjectMaskRenderer.clearCaches()
        needsAnotherPreviewRender = false
        originalPreviewAssetID = nil
        isEditingCrop = false
        thumbnailCache.clearMemory()
        pendingPhotoThumbnails = []
        exitZoom100()
        cullCache.clear()
        loupeImage = nil
        compareImage = nil
        compareAssetID = nil
        renderedPreview = nil
        originalPreview = nil
        histogram = .empty
        let renderer = photoRenderer
        let thumbnails = thumbnailRenderer
        Task {
            await renderer.evictAll()
            await thumbnails.clearRenderCaches()
        }
    }

    /// Projects saved before photo dimensions were recorded get them from file metadata.
    /// The saved snapshot is updated too, so this alone does not mark the project edited.
    private func backfillPhotoDimensions() {
        let targets = project.media
            .filter { $0.kind == .photo && ($0.pixelWidth == nil || $0.pixelHeight == nil) }
            .map { ($0.id, $0.url) }
        guard !targets.isEmpty else { return }
        let projectID = project.id

        Task {
            let found = await Task.detached {
                targets.compactMap { id, url in
                    PhotoSourceLoader.dimensions(of: url).map { (id, $0.width, $0.height) }
                }
            }.value
            guard project.id == projectID else { return }

            for (id, width, height) in found {
                if let index = project.media.firstIndex(where: { $0.id == id }) {
                    project.media[index].pixelWidth = width
                    project.media[index].pixelHeight = height
                }
                if let index = lastSavedProject.media.firstIndex(where: { $0.id == id }) {
                    lastSavedProject.media[index].pixelWidth = width
                    lastSavedProject.media[index].pixelHeight = height
                }
            }
        }
    }

    func isMissing(_ asset: MediaAsset) -> Bool {
        !FileManager.default.fileExists(atPath: asset.url.path)
    }

    func relink(_ asset: MediaAsset? = nil) {
        guard let target = asset ?? selectedAsset else {
            lastError = "Select a photo before relinking."
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Relink \(target.filename)"
        panel.prompt = "Relink"
        switch target.kind {
        case .photo:
            panel.allowedContentTypes = [.image, .rawImage]
        case .video:
            panel.allowedContentTypes = [.movie]
        case .audio:
            panel.allowedContentTypes = [.audio]
        }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let index = project.media.firstIndex(where: { $0.id == target.id }) else { return }

        var photoSize: (width: Int, height: Int)?
        if target.kind == .photo {
            guard let size = PhotoSourceLoader.dimensions(of: url) else {
                lastError = "The selected file is not a supported photo."
                return
            }
            photoSize = size
        }

        thumbnailCache.invalidate(assetID: target.id)
        pendingVideoThumbnails.remove(target.id)
        audioWaveforms[target.id] = nil
        pendingAudioWaveforms.remove(target.id)
        Task {
            await audioWaveformService.invalidate(url: target.url)
        }
        project.media[index].url = url
        if let photoSize {
            project.media[index].pixelWidth = photoSize.width
            project.media[index].pixelHeight = photoSize.height
            pendingPhotoThumbnails.remove(target.id)
            cullCache.remove(target.id)
            let renderer = photoRenderer
            let focus = focusRenderer
            let previousURL = target.url
            Task {
                await renderer.evict(url: previousURL)
                await focus.evict(url: previousURL)
            }
            rawInfoAssetID = nil
            originalPreviewAssetID = nil
            selectedAssetID = target.id
            refreshPreview()
        } else {
            // Drop the old file's proxy right away so it is never shown for the relinked clip.
            proxyStore.invalidate(assetID: target.id)
            Task {
                let metadata = await videoMediaService.metadata(for: url)
                guard let currentIndex = project.media.firstIndex(where: { $0.id == target.id }) else {
                    return
                }
                project.media[currentIndex].durationSeconds = metadata.durationSeconds
                project.media[currentIndex].pixelWidth = metadata.pixelWidth
                project.media[currentIndex].pixelHeight = metadata.pixelHeight
                proxyStore.enqueue([project.media[currentIndex]])
                if project.timelineClips.contains(where: { $0.assetID == target.id }) {
                    rebuildTimelinePlayback()
                }
            }
            selectVideo(project.media[index])
        }
        statusMessage = "Relinked \(url.lastPathComponent)"
    }

    func addToTimeline(_ asset: MediaAsset? = nil) {
        guard let asset = asset ?? selectedVideoAsset, asset.kind == .video else {
            lastError = "Select a video before adding it to the timeline."
            return
        }

        let duration = max(0.25, asset.durationSeconds ?? 5)
        let clip = TimelineClip(assetID: asset.id, durationSeconds: duration)
        project.timelineClips.append(clip)
        normalizePrimaryTimeline()
        selectedTimelineClipID = clip.id
        rebuildTimelinePlayback(seekTo: clip.timelineStartSeconds)
    }

    func selectTimelineClip(_ clip: TimelineClip) {
        selectedTimelineClipID = clip.id
        if let asset = project.media.first(where: { $0.id == clip.assetID }) {
            selectedVideoAssetID = asset.id
        }
        showTimelinePlayback(at: clip.timelineStartSeconds)
    }

    func playSelectedTimelineClip() {
        guard let clip = selectedTimelineClip else { return }
        showTimelinePlayback(at: clip.timelineStartSeconds, autoplay: true)
    }

    func removeSelectedTimelineClip() {
        guard let selectedTimelineClipID else { return }
        project.timelineClips.removeAll(where: { $0.id == selectedTimelineClipID })
        project.videoAdjustmentsByClipID.removeValue(forKey: selectedTimelineClipID)
        project.audioAdjustmentsByClipID.removeValue(forKey: selectedTimelineClipID)
        self.selectedTimelineClipID = project.timelineClips.first?.id
        normalizePrimaryTimeline()
        rebuildTimelinePlayback()
    }

    func moveSelectedTimelineClip(by offset: Int) {
        guard let selectedTimelineClipID,
              let index = project.timelineClips.firstIndex(where: { $0.id == selectedTimelineClipID })
        else { return }
        let destination = min(max(0, index + offset), project.timelineClips.count - 1)
        guard destination != index else { return }
        project.timelineClips.swapAt(index, destination)
        normalizePrimaryTimeline()
        rebuildTimelinePlayback(seekTo: project.timelineClips[destination].timelineStartSeconds)
    }

    func canMoveSelectedTimelineClip(by offset: Int) -> Bool {
        guard let selectedTimelineClipID,
              let index = project.timelineClips.firstIndex(where: { $0.id == selectedTimelineClipID })
        else { return false }
        return project.timelineClips.indices.contains(index + offset)
    }

    func trimSelectedClipStart(by delta: Double) {
        guard let selectedTimelineClipID,
              let index = project.timelineClips.firstIndex(where: { $0.id == selectedTimelineClipID }),
              let asset = project.media.first(where: { $0.id == project.timelineClips[index].assetID })
        else { return }

        let originalDuration = max(0.25, asset.durationSeconds ?? 5)
        let clip = project.timelineClips[index]
        let newStart = min(max(0, clip.sourceStartSeconds + delta), originalDuration - 0.25)
        let end = min(originalDuration, clip.sourceStartSeconds + clip.durationSeconds)
        project.timelineClips[index].sourceStartSeconds = newStart
        project.timelineClips[index].durationSeconds = max(0.25, end - newStart)
        normalizePrimaryTimeline()
        rebuildTimelinePlayback()
    }

    func trimSelectedClipEnd(by delta: Double) {
        guard let selectedTimelineClipID,
              let index = project.timelineClips.firstIndex(where: { $0.id == selectedTimelineClipID }),
              let asset = project.media.first(where: { $0.id == project.timelineClips[index].assetID })
        else { return }

        let originalDuration = max(0.25, asset.durationSeconds ?? 5)
        let maximum = max(0.25, originalDuration - project.timelineClips[index].sourceStartSeconds)
        project.timelineClips[index].durationSeconds = min(
            maximum,
            max(0.25, project.timelineClips[index].durationSeconds + delta)
        )
        normalizePrimaryTimeline()
        rebuildTimelinePlayback()
    }

    func splitSelectedClip() {
        guard let selectedTimelineClipID,
              let index = project.timelineClips.firstIndex(where: { $0.id == selectedTimelineClipID })
        else { return }
        let original = project.timelineClips[index]
        guard original.durationSeconds >= 0.5 else { return }

        let firstDuration = original.durationSeconds / 2
        project.timelineClips[index].durationSeconds = firstDuration
        let second = TimelineClip(
            assetID: original.assetID,
            videoTrack: original.videoTrack,
            audioTrack: original.audioTrack,
            sourceStartSeconds: original.sourceStartSeconds + firstDuration,
            durationSeconds: original.durationSeconds - firstDuration,
            isEnabled: original.isEnabled,
            isMuted: original.isMuted
        )
        project.timelineClips.insert(second, at: index + 1)
        if let adjustments = project.videoAdjustmentsByClipID[original.id] {
            project.videoAdjustmentsByClipID[second.id] = adjustments
        }
        if var adjustments = project.audioAdjustmentsByClipID[original.id] {
            let originalFadeOut = adjustments.fadeOutSeconds
            adjustments.fadeOutSeconds = 0
            project.audioAdjustmentsByClipID[original.id] = adjustments

            var secondAdjustments = adjustments
            secondAdjustments.fadeInSeconds = 0
            secondAdjustments.fadeOutSeconds = min(originalFadeOut, second.durationSeconds / 2)
            project.audioAdjustmentsByClipID[second.id] = secondAdjustments
        }
        self.selectedTimelineClipID = second.id
        normalizePrimaryTimeline()
        rebuildTimelinePlayback(seekTo: second.timelineStartSeconds)
    }

    func toggleSelectedClipMute() {
        guard let selectedTimelineClipID,
              let index = project.timelineClips.firstIndex(where: { $0.id == selectedTimelineClipID })
        else { return }
        project.timelineClips[index].isMuted.toggle()
        rebuildTimelinePlayback()
    }

    func previewTimeline() {
        showTimelinePlayback(at: timelinePlaybackPositionSeconds)
    }

    func toggleVideoPlayback() {
        guard let videoPlayer else {
            guard !project.timelineClips.isEmpty else { return }
            rebuildTimelinePlayback(autoplay: true)
            return
        }

        if isVideoPlaying || videoPlayer.timeControlStatus != .paused {
            videoPlayer.pause()
            isVideoPlaying = false
        } else {
            if isTimelinePlayback,
               timelinePlaybackDurationSeconds > 0,
               timelinePlaybackPositionSeconds >= timelinePlaybackDurationSeconds - 0.05 {
                seekTimeline(to: 0)
            }
            videoPlayer.play()
            isVideoPlaying = true
        }
    }

    func seekTimeline(to seconds: Double) {
        let clamped = min(max(0, seconds), timelinePlaybackDurationSeconds)
        guard isTimelinePlayback, let videoPlayer else {
            showTimelinePlayback(at: clamped)
            return
        }
        timelinePlaybackPositionSeconds = clamped
        videoPlayer.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        synchronizeTimelineSelection(at: clamped)
    }

    func timelineAsset(for clip: TimelineClip) -> MediaAsset? {
        project.media.first(where: { $0.id == clip.assetID })
    }

    func audioWaveform(for clip: TimelineClip) -> [Float] {
        audioWaveforms[clip.assetID] ?? []
    }

    private func requestAudioWaveform(for asset: MediaAsset) {
        guard asset.kind == .video || asset.kind == .audio,
              audioWaveforms[asset.id] == nil,
              !pendingAudioWaveforms.contains(asset.id)
        else { return }

        pendingAudioWaveforms.insert(asset.id)
        let assetID = asset.id
        let url = asset.url
        Task { [weak self] in
            guard let self else { return }
            let samples = await audioWaveformService.samples(for: url)
            pendingAudioWaveforms.remove(assetID)
            if !samples.isEmpty {
                audioWaveforms[assetID] = samples
            }
        }
    }

    private func mediaKind(for url: URL) -> MediaKind? {
        let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        if type?.conforms(to: .image) == true || type?.conforms(to: .rawImage) == true {
            return .photo
        }
        if type?.conforms(to: .movie) == true {
            return .video
        }
        if type?.conforms(to: .audio) == true {
            return .audio
        }
        return nil
    }

    private func showSourceVideo(_ asset: MediaAsset) {
        playbackRequestID = UUID()
        compositionRebuildTask?.cancel()
        timelinePlaybackWarnings = []
        timelinePlaybackDurationSeconds = 0
        timelinePlaybackPositionSeconds = 0
        replaceVideoPlayer(AVPlayer(url: playbackURL(for: asset)), timelineMode: false)
    }

    private static func proxyStatusKind(_ status: ProxyStatus) -> Int {
        switch status {
        case .missing: 0
        case .queued: 1
        case .generating: 2
        case .ready: 3
        case .failed: 4
        }
    }

    private func playbackURL(for asset: MediaAsset) -> URL {
        guard usesProxiesForPlayback else { return asset.url }
        regenerateMissingProxies(for: [asset.id])
        return proxyStore.readyURL(for: asset.id) ?? asset.url
    }

    /// A ready proxy whose file is gone (the user cleared the cache folder) is forgotten and queued
    /// again, so playback falls back to the original until the new proxy is ready.
    private func regenerateMissingProxies(for assetIDs: Set<UUID>) {
        let stale = assetIDs.filter { id in
            proxyStore.readyURL(for: id).map { !FileManager.default.fileExists(atPath: $0.path) } ?? false
        }
        guard !stale.isEmpty else { return }
        for id in stale { proxyStore.invalidate(assetID: id) }
        proxyStore.enqueue(project.media.filter { stale.contains($0.id) })
    }

    private func proxyBecameReady(_ assetID: UUID) {
        guard usesProxiesForPlayback else { return }
        if isTimelinePlayback {
            if project.timelineClips.contains(where: { $0.assetID == assetID }) {
                rebuildTimelinePlayback() // Keeps position and play state.
            }
        } else if selectedVideoAssetID == assetID, !isVideoPlaying,
                  let asset = project.media.first(where: { $0.id == assetID }) {
            // A background proxy never switches the viewer into timeline mode.
            showSourceVideo(asset)
        }
    }

    private func refreshPlaybackSources() {
        if isTimelinePlayback {
            rebuildTimelinePlayback()
        } else if let asset = selectedVideoAsset {
            showSourceVideo(asset)
        }
    }

    private func showTimelinePlayback(at seconds: Double, autoplay: Bool = false) {
        if isTimelinePlayback, videoPlayer != nil {
            seekTimeline(to: seconds)
            if autoplay {
                videoPlayer?.play()
                isVideoPlaying = true
            }
        } else {
            rebuildTimelinePlayback(autoplay: autoplay, seekTo: seconds)
        }
    }

    private func rebuildTimelinePlayback(
        autoplay: Bool = false,
        seekTo requestedPosition: Double? = nil
    ) {
        guard !project.timelineClips.isEmpty else {
            replaceVideoPlayer(nil, timelineMode: false)
            timelinePlaybackDurationSeconds = 0
            timelinePlaybackPositionSeconds = 0
            timelinePlaybackWarnings = []
            timelineUsedProxyCount = 0
            statusMessage = "Timeline is empty"
            return
        }

        let livePlayerPosition = videoPlayer?.currentTime().seconds
        let retainedPosition = livePlayerPosition.flatMap { $0.isFinite ? $0 : nil }
            ?? timelinePlaybackPositionSeconds
        let position = requestedPosition ?? (isTimelinePlayback ? retainedPosition : 0)
        let shouldAutoplay = autoplay || (isTimelinePlayback && isVideoPlaying)
        let clips = project.timelineClips
        let media = project.media
        let adjustmentsByClipID = project.videoAdjustmentsByClipID
        let audioAdjustmentsByClipID = project.audioAdjustmentsByClipID
        if usesProxiesForPlayback { regenerateMissingProxies(for: Set(clips.map(\.assetID))) }
        let proxyURLs = usesProxiesForPlayback ? proxyStore.readyURLs : [:]
        let requestID = UUID()
        playbackRequestID = requestID
        compositionRebuildTask?.cancel()
        statusMessage = "Building timeline preview…"

        compositionRebuildTask = Task { [weak self] in
            guard let self else { return }
            let result = await timelineCompositionService.makePlayerItem(
                clips: clips,
                media: media,
                adjustmentsByClipID: adjustmentsByClipID,
                audioAdjustmentsByClipID: audioAdjustmentsByClipID,
                quality: .preview,
                proxyURLsByAssetID: proxyURLs
            )
            guard !Task.isCancelled, playbackRequestID == requestID else { return }

            timelinePlaybackWarnings = result.warnings
            timelineUsedProxyCount = result.usedProxyCount
            guard let playerItem = result.playerItem else {
                replaceVideoPlayer(nil, timelineMode: false)
                timelinePlaybackDurationSeconds = 0
                timelinePlaybackPositionSeconds = 0
                statusMessage = result.warnings.first ?? "Timeline preview could not be built"
                return
            }

            let player = AVPlayer(playerItem: playerItem)
            replaceVideoPlayer(player, timelineMode: true)
            timelinePlaybackDurationSeconds = result.durationSeconds
            let clampedPosition = min(max(0, position), result.durationSeconds)
            seekTimeline(to: clampedPosition)
            if shouldAutoplay {
                player.play()
                isVideoPlaying = true
            }
            statusMessage = result.warnings.isEmpty
                ? "Timeline preview ready"
                : "Timeline ready with \(result.warnings.count) warning\(result.warnings.count == 1 ? "" : "s")"
        }
    }

    private func replaceVideoPlayer(_ player: AVPlayer?, timelineMode: Bool) {
        playbackMonitorTask?.cancel()
        videoPlayer?.pause()
        videoPlayer = player
        isTimelinePlayback = timelineMode
        isVideoPlaying = false

        guard let player else { return }
        playbackMonitorTask = Task { @MainActor [weak self, weak player] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let player, self.videoPlayer === player else { return }
                self.isVideoPlaying = player.timeControlStatus == .playing
                guard self.isTimelinePlayback else { continue }
                let seconds = player.currentTime().seconds
                guard seconds.isFinite else { continue }
                self.timelinePlaybackPositionSeconds = min(
                    max(0, seconds),
                    self.timelinePlaybackDurationSeconds
                )
                self.synchronizeTimelineSelection(at: seconds)
            }
        }
    }

    private func synchronizeTimelineSelection(at seconds: Double) {
        guard isTimelinePlayback else { return }
        let tolerance = 0.001
        let clip = project.timelineClips.first {
            seconds + tolerance >= $0.timelineStartSeconds &&
                seconds < $0.timelineStartSeconds + $0.durationSeconds - tolerance
        } ?? (seconds >= timelineDurationSeconds - tolerance ? project.timelineClips.last : nil)

        guard let clip else { return }
        if selectedTimelineClipID != clip.id {
            selectedTimelineClipID = clip.id
        }
        if selectedVideoAssetID != clip.assetID {
            selectedVideoAssetID = clip.assetID
        }
    }

    private func normalizePrimaryTimeline() {
        var cursor = 0.0
        for index in project.timelineClips.indices {
            project.timelineClips[index].timelineStartSeconds = cursor
            cursor += project.timelineClips[index].durationSeconds
        }
    }
}
