import AppKit
import AVFoundation
import Combine
import CoreImage
import UniformTypeIdentifiers

@MainActor
final class EditorStore: ObservableObject {
    @Published var project = EditorProject.starter
    @Published var workspace: Workspace = .library
    @Published var selectedAssetID: UUID?
    @Published var selectedVideoAssetID: UUID?
    @Published var selectedTimelineClipID: UUID?
    @Published var videoPlayer: AVPlayer?
    @Published private(set) var isTimelinePlayback = false
    @Published private(set) var isVideoPlaying = false
    @Published private(set) var timelinePlaybackPositionSeconds = 0.0
    @Published private(set) var timelinePlaybackDurationSeconds = 0.0
    @Published private(set) var timelinePlaybackWarnings: [String] = []
    @Published private(set) var videoThumbnails: [UUID: NSImage] = [:]
    @Published var renderedPreview: NSImage?
    @Published var originalPreview: NSImage?
    @Published var previewMode: PreviewMode = .edited
    @Published var histogram = HistogramData.empty
    @Published var userPresets: [PhotoPreset] = []
    @Published var statusMessage = "Ready"
    @Published var lastError: String?

    private(set) var sourceImages: [UUID: CIImage] = [:]
    private(set) var projectURL: URL?

    private let renderer = PhotoRenderer.shared
    private let document = ProjectDocument()
    private let userPresetRepository = UserPresetRepository()
    private let thumbnailCache = ThumbnailCache()
    private let videoMediaService = VideoMediaService.shared
    private let timelineCompositionService = TimelineCompositionService.shared
    private var pendingVideoThumbnails: Set<UUID> = []
    private var compositionRebuildTask: Task<Void, Never>?
    private var playbackMonitorTask: Task<Void, Never>?
    private var playbackRequestID = UUID()

    init() {
        userPresets = userPresetRepository.load()
    }

    var presets: [PhotoPreset] {
        PhotoPreset.builtIns + userPresets
    }

    var isShowingOriginal: Bool {
        previewMode == .original
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
            thumbnailCache.invalidate(assetID: selectedAssetID)
            refreshPreview()
        }
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

    func importURLs(_ urls: [URL]) {
        Task {
            await importURLsAsync(urls)
        }
    }

    private func importURLsAsync(_ urls: [URL]) async {
        var importedCount = 0
        var lastImportedKind: MediaKind?

        for url in urls {
            guard let kind = mediaKind(for: url) else { continue }

            switch kind {
            case .photo:
                guard let image = renderer.loadImage(from: url) else { continue }
                let asset = MediaAsset(url: url, kind: .photo)
                project.media.append(asset)
                project.adjustmentsByAssetID[asset.id] = .neutral
                sourceImages[asset.id] = image
                selectedAssetID = asset.id
                importedCount += 1
            case .video, .audio:
                let metadata = await videoMediaService.metadata(for: url)
                let asset = MediaAsset(
                    url: url,
                    kind: kind,
                    durationSeconds: metadata.durationSeconds,
                    pixelWidth: metadata.pixelWidth,
                    pixelHeight: metadata.pixelHeight
                )
                project.media.append(asset)
                selectedVideoAssetID = asset.id
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
        selectedAssetID = asset.id
        loadSourceIfNeeded(for: asset)
        refreshPreview()
    }

    func selectVideo(_ asset: MediaAsset) {
        guard asset.kind == .video || asset.kind == .audio else { return }
        selectedVideoAssetID = asset.id
        showSourceVideo(asset)
        statusMessage = "Selected \(asset.filename)"
    }

    func updateAdjustments(_ update: (inout PhotoAdjustments) -> Void) {
        guard selectedAssetID != nil else { return }
        var adjustments = selectedAdjustments
        update(&adjustments)
        selectedAdjustments = adjustments
    }

    func apply(_ preset: PhotoPreset) {
        selectedAdjustments = preset.adjustments
        statusMessage = "Applied \(preset.name)"
    }

    func saveUserPreset(named name: String) {
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedName.isEmpty, selectedAssetID != nil else { return }

        if let index = userPresets.firstIndex(where: {
            $0.name.localizedCaseInsensitiveCompare(cleanedName) == .orderedSame
        }) {
            userPresets[index].adjustments = selectedAdjustments
        } else {
            userPresets.append(
                PhotoPreset(
                    name: cleanedName,
                    category: "User",
                    adjustments: selectedAdjustments
                )
            )
        }

        userPresets.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        userPresetRepository.save(userPresets)
        statusMessage = "Saved preset \(cleanedName)"
    }

    func deleteUserPreset(_ preset: PhotoPreset) {
        userPresets.removeAll(where: { $0.id == preset.id })
        userPresetRepository.save(userPresets)
        statusMessage = "Deleted preset \(preset.name)"
    }

    func isUserPreset(_ preset: PhotoPreset) -> Bool {
        userPresets.contains(where: { $0.id == preset.id })
    }

    func resetAdjustments() {
        selectedAdjustments = .neutral
        statusMessage = "Adjustments reset"
    }

    func rotate(clockwise: Bool) {
        updateAdjustments { adjustments in
            let delta = clockwise ? 1 : -1
            adjustments.rotationQuarterTurns = (adjustments.rotationQuarterTurns + delta) % 4
        }
    }

    func refreshPreview() {
        guard let selectedAssetID else {
            renderedPreview = nil
            originalPreview = nil
            histogram = .empty
            return
        }

        if sourceImages[selectedAssetID] == nil, let asset = selectedAsset {
            loadSourceIfNeeded(for: asset)
        }

        guard let source = sourceImages[selectedAssetID] else {
            renderedPreview = nil
            originalPreview = nil
            histogram = .empty
            return
        }

        originalPreview = renderer.preview(source, adjustments: .neutral)
        renderedPreview = renderer.preview(source, adjustments: selectedAdjustments)
        histogram = renderer.histogram(source, adjustments: selectedAdjustments)
    }

    func setShowingOriginal(_ showing: Bool) {
        previewMode = showing ? .original : .edited
    }

    func newProject() {
        project = EditorProject.starter
        projectURL = nil
        selectedAssetID = nil
        selectedVideoAssetID = nil
        selectedTimelineClipID = nil
        playbackRequestID = UUID()
        compositionRebuildTask?.cancel()
        replaceVideoPlayer(nil, timelineMode: false)
        timelinePlaybackDurationSeconds = 0
        timelinePlaybackWarnings = []
        videoThumbnails = [:]
        pendingVideoThumbnails = []
        sourceImages = [:]
        renderedPreview = nil
        originalPreview = nil
        histogram = .empty
        previewMode = .edited
        thumbnailCache.clearMemory()
        workspace = .library
        statusMessage = "New project"
    }

    func saveProject(saveAs: Bool = false) {
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

        guard let destination else { return }

        do {
            try document.save(project, to: destination)
            projectURL = destination
            statusMessage = "Saved \(destination.lastPathComponent)"
        } catch {
            lastError = error.localizedDescription
        }
    }

    func openProject() {
        let panel = NSOpenPanel()
        panel.title = "Open Perception Media Project"
        panel.allowedContentTypes = [UTType(filenameExtension: ProjectDocument.fileExtension) ?? .json]
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            project = try document.load(from: url)
            projectURL = url
            selectedAssetID = nil
            selectedVideoAssetID = nil
            selectedTimelineClipID = project.timelineClips.first?.id
            sourceImages = [:]
            if let first = project.media.first {
                if first.kind == .photo {
                    selectedAssetID = first.id
                    loadSourceIfNeeded(for: first)
                } else {
                    selectVideo(first)
                }
            }
            refreshPreview()
            if !project.timelineClips.isEmpty {
                rebuildTimelinePlayback()
            }
            statusMessage = "Opened \(url.lastPathComponent)"
        } catch {
            lastError = error.localizedDescription
        }
    }

    func exportSelectedPhoto() {
        guard
            let selectedAssetID,
            let asset = selectedAsset
        else {
            lastError = "Select a photo before exporting."
            return
        }

        loadSourceIfNeeded(for: asset)
        guard let source = sourceImages[selectedAssetID] else {
            lastError = "The original file could not be loaded. Relink it from the Photo or Library workspace."
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export Edited Photo"
        panel.allowedContentTypes = [.jpeg, .png]
        panel.nameFieldStringValue = asset.url.deletingPathExtension().lastPathComponent + "_edited.jpg"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let type: UTType = url.pathExtension.lowercased() == "png" ? .png : .jpeg
        do {
            try renderer.export(source, adjustments: selectedAdjustments, to: url, type: type)
            statusMessage = "Exported \(url.lastPathComponent)"
        } catch {
            lastError = error.localizedDescription
        }
    }

    func thumbnail(for asset: MediaAsset) -> NSImage? {
        if asset.kind == .video {
            if let cached = thumbnailCache.image(for: asset, adjustments: .neutral) {
                return cached
            }
            if let image = videoThumbnails[asset.id] { return image }
            if !pendingVideoThumbnails.contains(asset.id) {
                pendingVideoThumbnails.insert(asset.id)
                Task {
                    let image = await videoMediaService.thumbnail(for: asset.url)
                    pendingVideoThumbnails.remove(asset.id)
                    if let image {
                        videoThumbnails[asset.id] = image
                        thumbnailCache.store(image, for: asset, adjustments: .neutral)
                    }
                }
            }
            return nil
        }

        guard asset.kind == .photo else { return nil }
        let adjustments = project.adjustmentsByAssetID[asset.id] ?? .neutral
        if let cached = thumbnailCache.image(for: asset, adjustments: adjustments) {
            return cached
        }

        loadSourceIfNeeded(for: asset)
        guard let source = sourceImages[asset.id] else { return nil }
        guard let image = renderer.preview(source, adjustments: adjustments, maxDimension: 420) else {
            return nil
        }
        thumbnailCache.store(image, for: asset, adjustments: adjustments)
        return image
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

        let photoSource: CIImage?
        if target.kind == .photo {
            guard let source = renderer.loadImage(from: url) else {
                lastError = "The selected file is not a supported photo."
                return
            }
            photoSource = source
        } else {
            photoSource = nil
        }

        thumbnailCache.invalidate(assetID: target.id)
        videoThumbnails[target.id] = nil
        pendingVideoThumbnails.remove(target.id)
        project.media[index].url = url
        if target.kind == .photo {
            sourceImages[target.id] = photoSource
            selectedAssetID = target.id
            refreshPreview()
        } else {
            Task {
                let metadata = await videoMediaService.metadata(for: url)
                guard let currentIndex = project.media.firstIndex(where: { $0.id == target.id }) else {
                    return
                }
                project.media[currentIndex].durationSeconds = metadata.durationSeconds
                project.media[currentIndex].pixelWidth = metadata.pixelWidth
                project.media[currentIndex].pixelHeight = metadata.pixelHeight
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
        rebuildTimelinePlayback()
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

    private func loadSourceIfNeeded(for asset: MediaAsset) {
        guard sourceImages[asset.id] == nil else { return }
        sourceImages[asset.id] = renderer.loadImage(from: asset.url)
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
        replaceVideoPlayer(AVPlayer(url: asset.url), timelineMode: false)
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
        let requestID = UUID()
        playbackRequestID = requestID
        compositionRebuildTask?.cancel()
        statusMessage = "Building timeline preview…"

        compositionRebuildTask = Task { [weak self] in
            guard let self else { return }
            let result = await timelineCompositionService.makePlayerItem(clips: clips, media: media)
            guard !Task.isCancelled, playbackRequestID == requestID else { return }

            timelinePlaybackWarnings = result.warnings
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
