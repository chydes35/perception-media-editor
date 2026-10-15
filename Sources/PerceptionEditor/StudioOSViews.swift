import AppKit
import SwiftUI

struct StudioOSPanel: View {
    @ObservedObject var controller: StudioOSController
    @EnvironmentObject private var store: EditorStore
    @State private var showConnect = false
    @State private var showDestinations = false
    @State private var isLoadingDestinations = false

    var body: some View {
        GroupBox("Studio OS") {
            VStack(alignment: .leading, spacing: 10) {
                statusRow
                HStack {
                    if controller.connection == nil {
                        Button("Connect to Studio OS…") { showConnect = true }
                    } else {
                        Button {
                            guard !isLoadingDestinations else { return }
                            isLoadingDestinations = true
                            Task {
                                // On failure the controller's error alert explains why; no empty sheet.
                                let loaded = await controller.loadDestinations()
                                isLoadingDestinations = false
                                if loaded { showDestinations = true }
                            }
                        } label: {
                            Label("Send Selected to Studio OS…", systemImage: "paperplane")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.selectedPhotosForExport.isEmpty || store.isExporting || transferRunning || isLoadingDestinations)
                        Button("Connection…") { showConnect = true }
                    }
                }
                if transferRunning && controller.connection != nil {
                    Text("A transfer is already running").font(.caption).foregroundStyle(.secondary)
                }
                Text("Photos arrive as private drafts. You review and publish them in Studio OS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(controller.transfers.sorted { $0.createdAt > $1.createdAt }) { record in
                    StudioOSTransferRow(record: record, controller: controller)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .sheet(isPresented: $showConnect) { StudioOSConnectSheet(controller: controller) }
        .sheet(isPresented: $showDestinations) {
            StudioOSDestinationSheet(controller: controller, photoCount: store.selectedPhotosForExport.count) { destination in
                store.sendSelectedToStudioOS(to: destination)
            }
        }
        .task {
            await controller.start()
            await controller.checkConnection()
        }
    }

    private var transferRunning: Bool { controller.transfers.contains { $0.status == .running } }

    @ViewBuilder private var statusRow: some View {
        switch controller.link {
        case .notPaired:
            Label("Not connected", systemImage: "circle").foregroundStyle(.secondary).font(.caption)
        case .checking:
            Label("Checking connection…", systemImage: "arrow.triangle.2.circlepath").font(.caption)
        case .connected(let storage):
            Label(storage == "ok" ? "Connected" : "Connected, but Studio OS storage is not responding",
                  systemImage: storage == "ok" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(storage == "ok" ? .green : .orange).font(.caption)
        case .unreachable(let detail):
            Label("Studio OS is not reachable (\(detail)). Is it running on this Mac?", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange).font(.caption)
        case .unauthorized:
            Label("Pairing was revoked or expired. Pair again from Studio OS.", systemImage: "key.slash")
                .foregroundStyle(.red).font(.caption)
        }
    }
}

struct StudioOSTransferRow: View {
    let record: TransferRecord
    @ObservedObject var controller: StudioOSController

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(record.destinationLabel).font(.callout.weight(.semibold))
                Spacer()
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
            ProgressView(value: record.fractionComplete)
            Text(countsText).font(.caption2).foregroundStyle(.secondary)
            if let reason = record.pausedReason, record.status == .paused {
                Text(reason).font(.caption).foregroundStyle(.orange)
            }
            ForEach(record.items.filter { $0.phase == .failed }) { item in
                Label("\(item.displayName): \(item.message ?? "Failed")", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
            }
            HStack {
                if record.status == .running {
                    Button("Cancel") { controller.cancel(record.id) }
                }
                if record.status == .paused || record.status == .cancelled {
                    Button("Resume") { controller.resume(record.id) }
                }
                if record.counts.failed > 0, record.status != .running {
                    Button("Retry failed") { controller.retryFailed(record.id) }
                }
                if let url = controller.openURL(for: record) {
                    Link("Open in Studio OS", destination: url)
                }
                Spacer()
                if record.status != .running {
                    Button("Discard local copy") { Task { await controller.discardLocal(record.id) } }
                        .help("Removes this app's staged files and this list entry. Nothing is deleted from Studio OS.")
                }
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    private var statusText: String {
        switch record.status {
        case .running: record.counts.queued > 0 ? "Preparing photos…" : (record.counts.rendered > 0 ? "Uploading…" : "Studio OS is preparing previews…")
        case .paused: "Paused"
        case .cancelled: "Stopped"
        case .completed: "Ready for review"
        }
    }

    private var countsText: String {
        let c = record.counts
        return "\(c.ready) ready · \(c.processing) processing · \(c.rendered) waiting to upload · \(c.queued) to prepare · \(c.failed) failed"
    }
}

struct StudioOSDestinationSheet: View {
    @ObservedObject var controller: StudioOSController
    let photoCount: Int
    let onSend: (StudioOSDestination) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var selection: String?

    private var filtered: [StudioOSDestination] {
        let matches = controller.destinations.filter {
            search.isEmpty || "\($0.clientName) \($0.shootType)".localizedCaseInsensitiveContains(search)
        }
        // The last destination is a suggestion shown first, never applied automatically.
        guard let last = controller.lastDestinationID else { return matches }
        return matches.filter { $0.galleryId == last } + matches.filter { $0.galleryId != last }
    }

    private var chosen: StudioOSDestination? { controller.destinations.first { $0.galleryId == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send to Studio OS").font(.title2.bold())
            TextField("Search client or shoot", text: $search).textFieldStyle(.roundedBorder)
            if controller.destinations.isEmpty {
                Text("No galleries found. Create a gallery on a booking in Studio OS first.")
                    .foregroundStyle(.secondary)
            }
            List(filtered, selection: $selection) { destination in
                VStack(alignment: .leading) {
                    Text("\(destination.clientName) — \(destination.shootType)")
                    HStack(spacing: 6) {
                        if let date = destination.scheduledAt {
                            Text(date.formatted(date: .abbreviated, time: .omitted))
                        }
                        if destination.galleryId == controller.lastDestinationID { Text("Last used") }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .tag(destination.galleryId)
            }
            .frame(minHeight: 220)
            if let chosen {
                Text("Send \(photoCount) photo\(photoCount == 1 ? "" : "s") to \(chosen.clientName) — \(chosen.shootType). They arrive as private drafts.")
                    .font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Send") {
                    if let chosen { onSend(chosen); dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(chosen == nil || photoCount == 0)
            }
        }
        .padding(20)
        .frame(width: 480, height: 460)
    }
}

struct StudioOSConnectSheet: View {
    @ObservedObject var controller: StudioOSController
    @Environment(\.dismiss) private var dismiss
    @State private var server = ""
    @State private var web = ""
    @State private var token = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Studio OS connection").font(.title2.bold())
            Text("Easiest: in Studio OS open Account → Pair a Mac and click the link it shows. Or enter the details by hand.")
                .font(.callout).foregroundStyle(.secondary)
            if let connection = controller.connection {
                Label("Paired with \(StudioOSPairing.displayOrigin(connection.serverURL))", systemImage: "checkmark.seal")
            }
            TextField("API address (e.g. http://localhost:3001)", text: $server).textFieldStyle(.roundedBorder)
            TextField("Web address, optional (e.g. http://localhost:3000)", text: $web).textFieldStyle(.roundedBorder)
            SecureField("Pairing token", text: $token).textFieldStyle(.roundedBorder)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }

            Divider()
            HStack {
                Text("Staging folder").frame(width: 100, alignment: .leading)
                Text(controller.stagingFolder.path).lineLimit(1).truncationMode(.middle).font(.caption)
                Spacer()
                Button("Choose…") { chooseStagingFolder() }
            }
            Text("Prepared JPEGs wait here until Studio OS confirms them, then they are deleted. Pick a folder on your external SSD for large shoots.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                if controller.connection != nil {
                    Button("Disconnect", role: .destructive) { controller.disconnect(); dismiss() }
                }
                Spacer()
                Button("Close") { dismiss() }
                Button("Pair") {
                    do {
                        try controller.pair(server: server, web: web.isEmpty ? nil : web, token: token)
                        token = ""
                        Task { await controller.checkConnection() }
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(server.isEmpty || token.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func chooseStagingFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Studio OS Staging Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { controller.stagingFolder = url }
    }
}

/// Shown when a `perceptionedit://pair` link arrives. Nothing is saved until the user agrees.
/// Also surfaces `controller.lastError`, which no other view displays.
struct StudioOSPairingAlert: ViewModifier {
    @ObservedObject var controller: StudioOSController
    @EnvironmentObject private var store: EditorStore
    /// True while the Pair button runs, so the alert's dismissal setter cannot cancel the pairing it is confirming.
    @State private var confirming = false

    func body(content: Content) -> some View {
        content
            .alert(
                "Pair with Studio OS?",
                isPresented: Binding(
                    get: { controller.pendingPairing != nil },
                    set: { if !$0, !confirming, controller.pendingPairing != nil { controller.cancelPendingPairing() } }
                ),
                actions: {
                    Button("Pair") {
                        confirming = true
                        do { try controller.confirmPendingPairing() } catch { store.lastError = error.localizedDescription }
                        confirming = false
                        Task { await controller.checkConnection() }
                    }
                    Button("Cancel", role: .cancel) { controller.cancelPendingPairing() }
                },
                message: {
                    Text(pairingMessage)
                }
            )
            .alert(
                "Studio OS",
                isPresented: Binding(
                    get: { controller.lastError != nil },
                    set: { if !$0 { controller.lastError = nil } }
                ),
                actions: { Button("OK") { controller.lastError = nil } },
                message: { Text(controller.lastError ?? "Unknown error") }
            )
    }

    private var pairingMessage: String {
        let target = controller.pendingPairing.map { StudioOSPairing.displayOrigin($0.serverURL) } ?? "this server"
        var text = "Photos you send will go to \(target). Only continue if you just started this from your own Studio OS."
        if let current = controller.connection.map({ StudioOSPairing.displayOrigin($0.serverURL) }) {
            text += " This replaces your current pairing with \(current)."
        }
        return text
    }
}
