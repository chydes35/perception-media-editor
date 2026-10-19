import Foundation

extension EditorStore {
    /// Starts Look Matching on every available photo. Analysis runs on `LookMatchService`, and
    /// a result that arrives after cancellation or project replacement is discarded.
    @discardableResult
    func startLookMatch() -> Task<Void, Never>? {
        guard !isRunningLookMatch else { return nil }
        selectedAgentKind = .lookMatching
        if let preflight = AgentEngine.lookMatchingPreflight(project: project) {
            discardLookMatch()
            latestAgentReport = preflight
            statusMessage = preflight.summary
            return nil
        }
        let photos = project.media.filter { $0.kind == .photo && !isMissing($0) }.map {
            LookMatchPhoto(id: $0.id, url: $0.url, adjustments: project.adjustmentsByAssetID[$0.id] ?? .neutral)
        }
        let request = LookMatchRequest(photos: photos, selectedID: selectedAssetID, thresholds: lookMatchThresholds)
        let projectID = project.id
        let generation = projectGeneration
        let requestID = UUID()
        let startedAt = Date.now
        lookMatchRequestID = requestID
        isRunningLookMatch = true
        lookMatchProgress = (0, photos.count * 2)
        statusMessage = "Look Match: analyzing \(photos.count) photos…"
        let service = lookMatchService
        let analyze = lookMatchAnalyzer
        let progress: @Sendable (Int, Int) -> Void = { [weak self] done, total in
            Task { @MainActor [weak self] in
                guard let self, isRunningLookMatch, lookMatchRequestID == requestID else { return }
                lookMatchProgress = (done, total)
            }
        }
        let task = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let result: LookMatchResult
                if let analyze { result = try await analyze(request) }
                else { result = try await service.analyze(request, progress: progress) }
                try Task.checkCancellation()
                self?.finishLookMatch(result, request: request, projectID: projectID,
                                      generation: generation, requestID: requestID, startedAt: startedAt)
            } catch {
                guard let self, lookMatchRequestID == requestID, projectGeneration == generation else { return }
                isRunningLookMatch = false
                lookMatchTask = nil
                if error is CancellationError { return }
                lastError = error.localizedDescription
                statusMessage = "Look Match could not be completed"
            }
        }
        lookMatchTask = task
        return task
    }

    func cancelLookMatch() {
        lookMatchTask?.cancel()
        lookMatchTask = nil
        lookMatchRequestID = UUID()
        if isRunningLookMatch {
            isRunningLookMatch = false
            statusMessage = "Look Match canceled"
        }
    }

    /// Clears an unapplied Look Match report so nothing from it can be applied later.
    func discardLookMatch() {
        lookMatchBaseline = nil
        if latestAgentReport?.kind == .lookMatching { latestAgentReport = nil }
    }

    func finishLookMatch(_ result: LookMatchResult, request: LookMatchRequest, projectID: UUID,
                         generation: UUID, requestID: UUID, startedAt: Date) {
        guard isRunningLookMatch, lookMatchRequestID == requestID else { return }
        isRunningLookMatch = false
        lookMatchTask = nil
        guard projectGeneration == generation, project.id == projectID else { return }
        let report = AgentEngine.lookMatchReport(result, project: project,
                                                 thresholds: request.thresholds, startedAt: startedAt)
        lookMatchBaseline = (report.id, Dictionary(request.photos.map { ($0.id, $0.adjustments) },
                                                   uniquingKeysWith: { a, _ in a }))
        latestAgentReport = report
        let flagged = report.proposedChanges.filter { !$0.isSelected }.count
        statusMessage = "Look Match: \(report.proposedChanges.count) proposals ready for review"
            + (flagged > 0 ? " (\(flagged) flagged)" : "")
    }

    func setLookMatchChange(_ id: UUID, selected: Bool) {
        guard var report = latestAgentReport,
              let index = report.proposedChanges.firstIndex(where: { $0.id == id && $0.kind == .matchLook })
        else { return }
        report.proposedChanges[index].isSelected = selected
        latestAgentReport = report
    }

    /// Applies the selected proposals as one "Look Match" undo step. A target edited since the
    /// analysis is skipped and reported instead of overwritten.
    func applyLookMatchChanges(_ report: AgentReport) {
        guard activeAdjustmentSnapshot == nil, !isRunningLookMatch else { return }
        cancelAutoAdjustment()
        let baseline = lookMatchBaseline?.reportID == report.id ? lookMatchBaseline?.adjustments ?? [:] : [:]
        let photoIDs = Set(project.media.filter { $0.kind == .photo }.map(\.id))
        let names = Dictionary(project.media.map { ($0.id, $0.filename) }, uniquingKeysWith: { a, _ in a })
        let before = project.adjustmentsByAssetID
        var applied = 0
        var skipped: [AgentFinding] = []
        for change in report.proposedChanges where change.kind == .matchLook && change.isSelected {
            guard let target = change.targetAssetID, let proposed = change.proposedAdjustments else { continue }
            guard photoIDs.contains(target), let analyzed = baseline[target],
                  (before[target] ?? .neutral) == analyzed else {
                skipped.append(AgentFinding(
                    severity: .medium,
                    title: "Edited since analysis",
                    detail: "\(names[target] ?? "A photo") changed after Look Matching ran, so its proposal was not applied.",
                    recommendation: "Run Look Matching again to include it.",
                    assetID: target
                ))
                continue
            }
            project.adjustmentsByAssetID[target] = proposed
            applied += 1
        }
        nextHistoryLabel = "Look Match"
        recordAdjustmentChange(before: before)
        lookMatchBaseline = nil
        latestAgentReport = AgentReport(
            id: report.id,
            kind: report.kind,
            startedAt: report.startedAt,
            finishedAt: .now,
            summary: "Applied Look Match to \(applied) photo\(applied == 1 ? "" : "s")"
                + (skipped.isEmpty ? "." : "; \(skipped.count) skipped because they changed after analysis."),
            findings: skipped + report.findings,
            proposedChanges: [],
            limitation: report.limitation
        )
        refreshPreview()
        statusMessage = "Look Match applied to \(applied) photo\(applied == 1 ? "" : "s"). Undo restores them all."
    }
}
