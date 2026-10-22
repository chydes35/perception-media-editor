import AppKit
import UniformTypeIdentifiers

struct TimelineExportState: Equatable {
    enum Phase: Equatable {
        case idle
        case exporting
        case finished(URL)
        case cancelled
        case failed(String)
    }

    var phase = Phase.idle
    var fraction = 0.0

    var isRunning: Bool { phase == .exporting }
}

extension EditorStore {
    /// Asks where to save, then exports the timeline with `timelineExportSettings`.
    func chooseTimelineExportDestination() {
        guard !project.timelineClips.isEmpty else {
            lastError = "Add clips to the timeline before exporting."
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export Timeline"
        panel.prompt = "Export"
        panel.nameFieldStringValue = "\(project.name).mov"
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try startTimelineExport(to: url)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Exports from originals, never proxies. Proxy generation pauses until the export ends, so
    /// the two never compete for the decoder and the disk.
    @discardableResult
    func startTimelineExport(to destination: URL) throws -> Task<Void, Never> {
        guard timelineExportTask == nil, !isExporting else { throw TimelineExportError.alreadyExporting }
        guard !project.timelineClips.isEmpty else { throw TimelineExportError.nothingToExport("The timeline has no clips to export.") }
        let inputLUTs = resolvedInputLUTs()
        let job = TimelineExportJob(
            clips: project.timelineClips, media: project.media,
            adjustmentsByClipID: project.videoAdjustmentsByClipID,
            audioAdjustmentsByClipID: project.audioAdjustmentsByClipID,
            sequenceFrameRate: project.sequenceFrameRate, masterGainDecibels: project.masterGainDecibels,
            inputLUTsByAssetID: inputLUTs.resolved,
            ocioInputsByAssetID: resolvedOCIOInputs()
        )
        let settings = timelineExportSettings
        let exporter = timelineExporter
        let generation = projectGeneration
        timelineExport = TimelineExportState(phase: .exporting)
        statusMessage = "Exporting timeline (\(settings.preset.rawValue))…"
        proxyStore.pause()

        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in
                guard let self, self.projectGeneration == generation, self.timelineExport.isRunning else { return }
                self.timelineExport.fraction = fraction
            }
        }
        let task = Task { [weak self] in
            let outcome: Result<TimelineExportResult, Error>
            do {
                outcome = .success(try await exporter.export(job, settings: settings, to: destination, progress: report))
            } catch {
                outcome = .failure(error)
            }
            guard let self else { return }
            proxyStore.resume()
            timelineExportTask = nil
            guard projectGeneration == generation else { return }
            switch outcome {
            case .success(let result):
                timelineExport = TimelineExportState(phase: .finished(result.url), fraction: 1)
                statusMessage = "Exported \(result.frameCount) frames to \(result.url.lastPathComponent) in \(Int(result.seconds.rounded())) s"
            case .failure(is CancellationError):
                timelineExport = TimelineExportState(phase: .cancelled)
                statusMessage = "Timeline export cancelled"
            case .failure(let error):
                timelineExport = TimelineExportState(phase: .failed(error.localizedDescription))
                lastError = error.localizedDescription
                statusMessage = "Timeline export failed"
            }
        }
        timelineExportTask = task
        return task
    }

    func cancelTimelineExport() {
        timelineExportTask?.cancel()
        if timelineExportTask != nil { statusMessage = "Stopping timeline export…" }
    }

    func invalidateTimelineExport() {
        timelineExportTask?.cancel()
        timelineExport = TimelineExportState()
    }
}
