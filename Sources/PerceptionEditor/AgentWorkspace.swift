import SwiftUI

struct AgentWorkspace: View {
    @EnvironmentObject private var store: EditorStore

    var body: some View {
        HSplitView {
            agentList
                .frame(minWidth: 245, idealWidth: 280, maxWidth: 330)
            reportView
                .frame(minWidth: 700, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var agentList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("WORKFLOW AGENTS")
                .font(.caption.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(AgentKind.allCases) { kind in
                        Button {
                            store.selectedAgentKind = kind
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: kind.symbol)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(kind.rawValue)
                                        .font(.callout.weight(.medium))
                                    Text(kind.description)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                            }
                            .padding(9)
                            .background(
                                store.selectedAgentKind == kind ? Color.accentColor.opacity(0.14) : .clear,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Spacer()
            Text("Developer source reviewers are available from scripts/agent-review.sh.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(15)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var reportView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(store.selectedAgentKind.rawValue, systemImage: store.selectedAgentKind.symbol)
                    .font(.title2.weight(.semibold))
                Spacer()
                if store.selectedAgentKind == .lookMatching && store.isRunningLookMatch {
                    ProgressView(value: Double(store.lookMatchProgress.done),
                                 total: Double(max(1, store.lookMatchProgress.total)))
                        .frame(width: 160)
                        .accessibilityLabel("Look Match progress")
                    Button("Cancel", role: .cancel) {
                        store.cancelLookMatch()
                    }
                } else {
                    Button("Run Agent", systemImage: "play.fill") {
                        store.runSelectedAgent()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
            }
            .padding(20)

            Divider()

            if let report = store.latestAgentReport, report.kind == store.selectedAgentKind {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(report.summary)
                            .font(.headline)

                        if report.proposedChanges.contains(where: { $0.kind == .matchLook }) {
                            lookMatchProposals(report)
                        } else if !report.proposedChanges.isEmpty {
                            GroupBox("Proposed changes") {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("\(report.proposedChanges.count) reversible project change\(report.proposedChanges.count == 1 ? "" : "s") are ready for review.")
                                        .font(.callout)
                                    ForEach(report.proposedChanges) { change in
                                        Label(change.detail, systemImage: "arrow.right.circle")
                                            .font(.caption)
                                    }
                                    Button("Apply Proposed Changes") {
                                        store.applyLatestAgentChanges()
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.orange)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                            }
                        }

                        GroupBox("Findings") {
                            if report.findings.isEmpty {
                                Label("No findings", systemImage: "checkmark.circle")
                                    .foregroundStyle(.green)
                            } else {
                                VStack(alignment: .leading, spacing: 12) {
                                    ForEach(report.findings) { finding in
                                        findingRow(finding)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                            }
                        }

                        if let limitation = report.limitation {
                            GroupBox("Current boundary") {
                                Text(limitation)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                            }
                        }
                    }
                    .padding(22)
                }
            } else {
                ContentUnavailableView(
                    "Run an agent",
                    systemImage: store.selectedAgentKind.symbol,
                    description: Text("The agent will inspect the current project and show a reviewable report here.")
                )
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Look Match

    private func lookMatchProposals(_ report: AgentReport) -> some View {
        let changes = report.proposedChanges.filter { $0.kind == .matchLook }
        let selected = changes.filter(\.isSelected).count
        let scenes = Array(Set(changes.compactMap(\.sceneIndex))).sorted()
        return GroupBox("Proposed matches") {
            VStack(alignment: .leading, spacing: 14) {
                Text("\(selected) of \(changes.count) selected. Flagged matches are left unselected; nothing changes until you apply.")
                    .font(.callout)
                ForEach(scenes, id: \.self) { scene in
                    let sceneChanges = changes.filter { $0.sceneIndex == scene }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Scene \(scene) · hero \(filename(sceneChanges.first?.sourceAssetID))")
                            .font(.callout.weight(.semibold))
                        ForEach(sceneChanges) { change in
                            lookMatchRow(change)
                        }
                    }
                }
                HStack {
                    Button("Apply Selected (\(selected))") {
                        store.applyLatestAgentChanges()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(selected == 0)
                    Button("Cancel") {
                        store.discardLookMatch()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private func lookMatchRow(_ change: AgentChange) -> some View {
        let flagged = (change.confidence ?? 1) < store.lookMatchThresholds.minimumConfidence
        let asset = store.project.media.first { $0.id == change.targetAssetID }
        return HStack(spacing: 10) {
            Toggle(isOn: Binding(
                get: { change.isSelected },
                set: { store.setLookMatchChange(change.id, selected: $0) }
            )) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("Apply match to \(asset?.filename ?? "photo")")
            Group {
                if let asset, let image = store.thumbnail(for: asset) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Color.secondary.opacity(0.15)
                }
            }
            .frame(width: 54, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(asset?.filename ?? "Missing photo")
                .font(.callout)
                .lineLimit(1)
            Spacer()
            if flagged {
                Label("Flagged", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            Text(change.confidence.map { "\(Int(($0 * 100).rounded()))%" } ?? "–")
                .font(.caption.monospacedDigit())
                .foregroundStyle(flagged ? .orange : .secondary)
                .frame(width: 40, alignment: .trailing)
                .accessibilityLabel("Confidence \(change.confidence.map { "\(Int(($0 * 100).rounded())) percent" } ?? "unknown")")
        }
    }

    private func filename(_ id: UUID?) -> String {
        store.project.media.first { $0.id == id }?.filename ?? "unknown"
    }

    private func findingRow(_ finding: AgentFinding) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(finding.severity.rawValue.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(color(for: finding.severity))
                .frame(width: 62, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(finding.title)
                    .font(.callout.weight(.semibold))
                Text(finding.detail)
                    .font(.caption)
                if let recommendation = finding.recommendation {
                    Text(recommendation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func color(for severity: AgentSeverity) -> Color {
        switch severity {
        case .critical: .red
        case .high: .orange
        case .medium: .yellow
        case .low: .blue
        case .info: .secondary
        }
    }
}
