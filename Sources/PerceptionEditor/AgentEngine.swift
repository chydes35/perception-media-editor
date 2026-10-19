import Foundation

enum AgentEngine {
    static func run(
        _ kind: AgentKind,
        project: EditorProject,
        selectedAssetID: UUID?
    ) -> AgentReport {
        let startedAt = Date.now
        let result: (String, [AgentFinding], [AgentChange], String?)

        switch kind {
        case .photoCulling:
            result = culling(project: project)
        case .lookMatching:
            // Image analysis runs in the background through EditorStore.startLookMatch().
            if let preflight = lookMatchingPreflight(project: project) { return preflight }
            result = (
                "Look Matching analyzes the photos in the background. Run it from the Agents workspace.",
                [],
                [],
                nil
            )
        case .batchEditing:
            result = batchEditing(project: project, selectedAssetID: selectedAssetID)
        case .photoQuality:
            result = photoQuality(project: project)
        case .videoContinuity:
            result = videoContinuity(project: project)
        case .delivery:
            result = delivery(project: project)
        case .metadata:
            result = metadata(project: project)
        case .relink:
            result = relink(project: project)
        case .projectHealth:
            result = projectHealth(project: project)
        }

        return AgentReport(
            kind: kind,
            startedAt: startedAt,
            summary: result.0,
            findings: result.1.sorted { $0.severity.sortOrder < $1.severity.sortOrder },
            proposedChanges: result.2,
            limitation: result.3
        )
    }

    private static func culling(
        project: EditorProject
    ) -> (String, [AgentFinding], [AgentChange], String?) {
        let photos = project.media.filter { $0.kind == .photo }
        guard !photos.isEmpty else {
            return (
                "No photos are available to cull.",
                [AgentFinding(severity: .info, title: "Photo set is empty", detail: "Import photos before running the culling pass.")],
                [],
                "Sharpness, eyes, exposure, and duplicate-frame scoring require image analysis beyond this local metadata pass."
            )
        }

        var findings: [AgentFinding] = []
        for asset in photos where !FileManager.default.fileExists(atPath: asset.url.path) {
            findings.append(AgentFinding(
                severity: .critical,
                title: "Missing original",
                detail: asset.filename,
                recommendation: "Relink the original before making a culling decision.",
                assetID: asset.id
            ))
        }

        let groups = Dictionary(grouping: photos, by: { $0.filename.lowercased() })
        for (filename, assets) in groups where assets.count > 1 {
            let locations = assets.map { $0.url.deletingLastPathComponent().path }.joined(separator: "; ")
            findings.append(AgentFinding(
                severity: .medium,
                title: "Duplicate filename group",
                detail: "\(filename) appears \(assets.count) times in \(locations).",
                recommendation: "Compare the frames manually and keep the strongest take."
            ))
        }

        for asset in photos {
            guard let width = asset.pixelWidth, let height = asset.pixelHeight,
                  min(width, height) < 1200
            else { continue }
            findings.append(AgentFinding(
                severity: .low,
                title: "Low-resolution source",
                detail: "\(asset.filename) is \(width)×\(height), below the 1200 px review threshold.",
                recommendation: "Confirm that this is intentional before using it for print or large delivery.",
                assetID: asset.id
            ))
        }

        return (
            "Reviewed \(photos.count) photo\(photos.count == 1 ? "" : "s"); \(findings.count) culling item\(findings.count == 1 ? "" : "s") need attention.",
            findings,
            [],
            "This local pass does not yet score focus, eyes, expressions, exposure quality, or near-duplicate frames."
        )
    }

    static let lookMatchingLimitation = "Look Matching adapts global exposure, white balance and look settings per photo. It does not yet re-detect subject or sky masks, check skin tones, or review flagged photos with AI."

    /// A report when Look Matching cannot help yet, or nil when analysis should run.
    static func lookMatchingPreflight(project: EditorProject) -> AgentReport? {
        let startedAt = Date.now
        let photos = project.media.filter { $0.kind == .photo }
        if photos.count < 2 {
            return AgentReport(
                kind: .lookMatching, startedAt: startedAt,
                summary: "Look Matching needs at least two photos.",
                findings: [AgentFinding(severity: .info, title: "Not enough photos",
                                        detail: "Import a shoot, edit one hero photo per scene, then run Look Matching.")],
                limitation: lookMatchingLimitation
            )
        }
        guard photos.contains(where: { LookMatchScenes.lookGroupCount(project.adjustmentsByAssetID[$0.id]) > 0 }) else {
            return AgentReport(
                kind: .lookMatching, startedAt: startedAt,
                summary: "Edit one hero photo in each scene before matching.",
                findings: [AgentFinding(severity: .high, title: "No edited hero photo",
                                        detail: "None of the \(photos.count) photos has a look edit to match.",
                                        recommendation: "Edit one photo per lighting scene, then run Look Matching again.")],
                limitation: lookMatchingLimitation
            )
        }
        return nil
    }

    /// Turns analysis into a reviewable report. Flagged proposals start unselected.
    static func lookMatchReport(
        _ result: LookMatchResult,
        project: EditorProject,
        thresholds: LookMatchThresholds,
        startedAt: Date
    ) -> AgentReport {
        let names = Dictionary(project.media.map { ($0.id, $0.filename) }, uniquingKeysWith: { a, _ in a })
        func name(_ id: UUID?) -> String { id.flatMap { names[$0] } ?? "an unknown photo" }
        var findings: [AgentFinding] = []
        var changes: [AgentChange] = []

        for scene in result.scenes {
            let range = scene.assetIDs.count == 1 ? name(scene.assetIDs.first)
                : "\(name(scene.assetIDs.first)) – \(name(scene.assetIDs.last))"
            if scene.heroID == nil {
                findings.append(AgentFinding(
                    severity: .medium,
                    title: "Scene \(scene.index) needs a hero",
                    detail: "\(scene.assetIDs.count) photo\(scene.assetIDs.count == 1 ? "" : "s") (\(range)) have no edited photo, so nothing was proposed. Suggested hero: \(name(scene.suggestedHeroID)).",
                    recommendation: "Edit \(name(scene.suggestedHeroID)), then run Look Matching again.",
                    assetID: scene.suggestedHeroID
                ))
            }
            for id in scene.alreadyEdited {
                findings.append(AgentFinding(
                    severity: .info,
                    title: "Already edited",
                    detail: "\(name(id)) in scene \(scene.index) already has its own look and was left unchanged.",
                    assetID: id
                ))
            }
            for id in scene.unreadable {
                findings.append(AgentFinding(
                    severity: .high,
                    title: "Could not analyze",
                    detail: "\(name(id)) in scene \(scene.index) could not be read at analysis size.",
                    recommendation: "Check that the original is available, then run Look Matching again.",
                    assetID: id
                ))
            }
            for proposal in scene.proposals {
                changes.append(AgentChange(
                    kind: .matchLook,
                    sourceAssetID: proposal.heroID,
                    targetAssetID: proposal.targetID,
                    detail: "Match \(name(proposal.targetID)) to \(name(proposal.heroID)).",
                    proposedAdjustments: proposal.adjustments,
                    confidence: proposal.confidence,
                    sceneIndex: scene.index,
                    isSelected: !proposal.isFlagged
                ))
            }
        }

        let flagged = changes.filter { !$0.isSelected }.count
        if flagged > 0 {
            findings.append(AgentFinding(
                severity: .low,
                title: "\(flagged) low-confidence match\(flagged == 1 ? "" : "es")",
                detail: "Below \(Int((thresholds.minimumConfidence * 100).rounded()))% confidence. These are flagged and left unselected.",
                recommendation: "Compare them with the hero before selecting, or edit them by hand."
            ))
        }
        let heroes = result.scenes.filter { $0.heroID != nil }.count
        let photoCount = result.scenes.reduce(0) { $0 + $1.assetIDs.count }
        let sceneCount = result.scenes.count
        return AgentReport(
            kind: .lookMatching,
            startedAt: startedAt,
            summary: "Found \(sceneCount) scene\(sceneCount == 1 ? "" : "s") in \(photoCount) photo\(photoCount == 1 ? "" : "s") and prepared \(changes.count) proposal\(changes.count == 1 ? "" : "s") from \(heroes) hero\(heroes == 1 ? "" : "es")\(flagged > 0 ? " (\(flagged) flagged)" : "").",
            findings: findings.sorted { $0.severity.sortOrder < $1.severity.sortOrder },
            proposedChanges: changes,
            limitation: lookMatchingLimitation
        )
    }

    private static func batchEditing(
        project: EditorProject,
        selectedAssetID: UUID?
    ) -> (String, [AgentFinding], [AgentChange], String?) {
        guard let selectedAssetID,
              let source = project.media.first(where: { $0.id == selectedAssetID && $0.kind == .photo })
        else {
            return (
                "Select a photo whose adjustments should be used for the batch.",
                [AgentFinding(severity: .high, title: "Batch source required", detail: "Choose and edit a reference photo first.")],
                [],
                nil
            )
        }

        let targets = project.media.filter { $0.kind == .photo && $0.id != source.id }
        let changes = targets.map {
            AgentChange(
                kind: .copyPhotoAdjustments,
                sourceAssetID: source.id,
                targetAssetID: $0.id,
                detail: "Apply \(source.filename)'s current adjustments to \($0.filename)."
            )
        }
        return (
            "Prepared a reversible batch adjustment proposal for \(changes.count) photo\(changes.count == 1 ? "" : "s").",
            [AgentFinding(
                severity: changes.isEmpty ? .info : .medium,
                title: "Batch changes require approval",
                detail: "The proposal changes project metadata only and leaves source files untouched.",
                recommendation: changes.isEmpty ? nil : "Apply after checking that the photos share a similar lighting setup."
            )],
            changes,
            "Selection filtering, scene grouping, and outlier detection are reserved for the next batch pass."
        )
    }

    private static func photoQuality(
        project: EditorProject
    ) -> (String, [AgentFinding], [AgentChange], String?) {
        let photos = project.media.filter { $0.kind == .photo }
        var findings: [AgentFinding] = []
        for asset in photos {
            if !FileManager.default.fileExists(atPath: asset.url.path) {
                findings.append(AgentFinding(severity: .critical, title: "Photo cannot be read", detail: asset.filename, recommendation: "Relink the original.", assetID: asset.id))
            } else if asset.pixelWidth == nil || asset.pixelHeight == nil {
                findings.append(AgentFinding(severity: .medium, title: "Dimensions unavailable", detail: asset.filename, recommendation: "Refresh the asset metadata before delivery.", assetID: asset.id))
            }
        }
        if photos.isEmpty {
            findings.append(AgentFinding(severity: .info, title: "No photos to inspect", detail: "Import a photo set to run quality checks."))
        }
        return (
            "Checked \(photos.count) photo\(photos.count == 1 ? "" : "s") for basic delivery readiness.",
            findings,
            [],
            "Pixel-level focus, clipping, noise, halo, and skin-tone analysis will require a Vision/Core Image analysis pass."
        )
    }

    private static func videoContinuity(
        project: EditorProject
    ) -> (String, [AgentFinding], [AgentChange], String?) {
        let videos = project.media.filter { $0.kind == .video }
        var findings: [AgentFinding] = []
        for asset in videos where !FileManager.default.fileExists(atPath: asset.url.path) {
            findings.append(AgentFinding(severity: .critical, title: "Missing video source", detail: asset.filename, recommendation: "Relink before playback or export.", assetID: asset.id))
        }
        for asset in videos where (asset.durationSeconds ?? 0) <= 0 {
            findings.append(AgentFinding(severity: .high, title: "Video duration unavailable", detail: asset.filename, recommendation: "Refresh metadata or confirm the codec is supported.", assetID: asset.id))
        }
        let dimensions: Set<String> = Set(videos.compactMap { asset in
            guard let width = asset.pixelWidth, let height = asset.pixelHeight else { return nil }
            return "\(width)×\(height)"
        })
        if dimensions.count > 1 {
            findings.append(AgentFinding(severity: .medium, title: "Mixed frame sizes", detail: "The project contains \(dimensions.sorted().joined(separator: ", ")).", recommendation: "Choose an explicit sequence frame size before export."))
        }
        if project.timelineClips.isEmpty && !videos.isEmpty {
            findings.append(AgentFinding(severity: .low, title: "Timeline is empty", detail: "Video sources exist but no clips are assembled.", recommendation: "Add selects to the timeline before delivery."))
        }
        return (
            "Checked \(videos.count) video source\(videos.count == 1 ? "" : "s") and \(project.timelineClips.count) timeline clip\(project.timelineClips.count == 1 ? "" : "s").",
            findings,
            [],
            "Frame-rate, audio-sync, black-frame, exposure-drift, and continuity analysis are not yet available in the local metadata pass."
        )
    }

    private static func delivery(
        project: EditorProject
    ) -> (String, [AgentFinding], [AgentChange], String?) {
        let photos = project.media.filter { $0.kind == .photo }
        let missing = photos.filter { !FileManager.default.fileExists(atPath: $0.url.path) }
        let findings = missing.map {
            AgentFinding(severity: .critical, title: "Delivery item is missing", detail: $0.filename, recommendation: "Relink or remove it from the delivery set.", assetID: $0.id)
        } + (photos.isEmpty ? [AgentFinding(severity: .info, title: "Delivery set is empty", detail: "Import photos before creating a delivery plan.")] : [])
        return (
            "Prepared a photo delivery checklist for \(photos.count) item\(photos.count == 1 ? "" : "s"). No files were written.",
            findings,
            [],
            "Export recipes, batch writing, metadata embedding, watermarking, and manifests are the next delivery implementation step."
        )
    }

    private static func metadata(
        project: EditorProject
    ) -> (String, [AgentFinding], [AgentChange], String?) {
        let assetsWithoutDimensions = project.media.filter { $0.kind == .photo && ($0.pixelWidth == nil || $0.pixelHeight == nil) }
        let findings = assetsWithoutDimensions.map {
            AgentFinding(severity: .medium, title: "Metadata gap", detail: "Camera and dimension metadata are incomplete for \($0.filename).", recommendation: "Read metadata from the original before organizing or exporting.", assetID: $0.id)
        }
        return (
            "Reviewed metadata readiness for \(project.media.count) project asset\(project.media.count == 1 ? "" : "s").",
            findings,
            [],
            "Keyword suggestions, IPTC editing, camera/lens extraction, and saved collections require a richer metadata model."
        )
    }

    private static func relink(
        project: EditorProject
    ) -> (String, [AgentFinding], [AgentChange], String?) {
        let missing = project.media.filter { !FileManager.default.fileExists(atPath: $0.url.path) }
        let findings = missing.map {
            AgentFinding(severity: .critical, title: "Relink candidate needed", detail: "The original for \($0.filename) is unavailable at its saved path.", recommendation: "Choose a search folder and verify the proposed match before relinking.", assetID: $0.id)
        }
        return (
            missing.isEmpty ? "All project originals are currently available." : "Found \(missing.count) missing original\(missing.count == 1 ? "" : "s").",
            findings,
            [],
            "The safe search-and-verify UI is not automated yet because relinking changes project references."
        )
    }

    private static func projectHealth(
        project: EditorProject
    ) -> (String, [AgentFinding], [AgentChange], String?) {
        var findings: [AgentFinding] = []
        if project.media.isEmpty {
            findings.append(AgentFinding(severity: .high, title: "Project has no media", detail: "Import photos, video, or audio to begin a production workflow."))
        }
        if project.media.contains(where: { $0.kind == .photo }) && project.adjustmentsByAssetID.isEmpty {
            findings.append(AgentFinding(severity: .medium, title: "Photo adjustments are not initialized", detail: "Photo assets exist without adjustment records.", recommendation: "Initialize neutral adjustments during import or migration."))
        }
        if project.media.contains(where: { $0.kind == .video }) && project.timelineClips.isEmpty {
            findings.append(AgentFinding(severity: .low, title: "Video sources are not assembled", detail: "The project contains video but no timeline sequence.", recommendation: "Add selects to the timeline."))
        }
        let missing = project.media.filter { !FileManager.default.fileExists(atPath: $0.url.path) }.count
        if missing > 0 {
            findings.append(AgentFinding(severity: .critical, title: "Project has missing originals", detail: "\(missing) reference\(missing == 1 ? "" : "s") cannot be read.", recommendation: "Run Relink & Recovery before editing."))
        }
        return (
            "Reviewed project health across \(project.media.count) media item\(project.media.count == 1 ? "" : "s").",
            findings,
            [],
            "The developer-facing source reviewers live in scripts/agent-review.sh and are intended to run from the repository."
        )
    }
}
