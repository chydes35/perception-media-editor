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
                Button("Run Agent", systemImage: "play.fill") {
                    store.runSelectedAgent()
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
            .padding(20)

            Divider()

            if let report = store.latestAgentReport, report.kind == store.selectedAgentKind {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(report.summary)
                            .font(.headline)

                        if !report.proposedChanges.isEmpty {
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
