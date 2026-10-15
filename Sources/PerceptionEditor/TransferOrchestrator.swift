import CryptoKit
import Foundation

struct TransferRuntime: Sendable {
    var api: any StudioOSAPI
    var store: TransferQueueStore
    /// Renders one item's JPEG at the destination URL. The default (Task 5) uses `PhotoRenderer`.
    var render: @Sendable (TransferItemRecord, URL, TransferRecord) async throws -> Void
    var freeSpace: @Sendable (URL) -> Int64 = TransferRuntime.volumeFreeSpace
    var onChange: @Sendable (TransferRecord) -> Void = { _ in }
    var pollInterval: Duration = .seconds(3)
    var maxUploads = 2
    var maxPollRounds = 200
    var estimatedBytesPerPhoto: Int64 = 30_000_000

    static func volumeFreeSpace(_ url: URL) -> Int64 {
        let probe = FileManager.default.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}

enum TransferError: LocalizedError, Equatable {
    case insufficientSpace(needed: Int64, available: Int64)
    case nothingToSend
    case stillProcessing

    var errorDescription: String? {
        switch self {
        case .insufficientSpace(let needed, let available):
            let format = ByteCountFormatter()
            return "Not enough free space to prepare these photos: about \(format.string(fromByteCount: needed)) needed, \(format.string(fromByteCount: available)) available. Choose a different staging folder or free up space."
        case .nothingToSend: return "None of the selected photos could be prepared for upload."
        case .stillProcessing: return "Studio OS is still preparing previews. Resume to keep checking."
        }
    }
}

enum TransferHashing {
    /// Streams the file in 1 MiB chunks off the calling actor.
    static func sha256(of url: URL) async throws -> (hex: String, size: Int64) {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            var total: Int64 = 0
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
                total += Int64(chunk.count)
            }
            return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), total)
        }.value
    }
}

/// Runs one transfer: render → create manifest → upload → wait for previews. Every state change
/// is written to the store first, so a crash or quit at any point resumes from the last
/// completed step. `run` never throws; its outcome is the stored status.
actor TransferOrchestrator {
    private let runtime: TransferRuntime

    init(_ runtime: TransferRuntime) { self.runtime = runtime }

    func run(_ id: String) async {
        do {
            try await execute(id)
        } catch is CancellationError {
            await finish(id, status: .cancelled, reason: nil)
        } catch let error as StudioOSError {
            await finish(id, status: .paused, reason: error.localizedDescription)
        } catch let error as TransferError {
            await finish(id, status: .paused, reason: error.localizedDescription)
        } catch {
            await finish(id, status: .paused, reason: error.localizedDescription)
        }
    }

    /// Re-queues photos that failed after the server manifest existed (upload rejection or preview
    /// failure). Photos that failed to render are not retried here: the manifest is fixed.
    func retryFailedItems(_ id: String) async {
        let updated = try? await runtime.store.update(id: id) { record in
            for index in record.items.indices
            where record.items[index].phase == .failed && record.items[index].remoteItemID != nil
                && record.items[index].stagedPath != nil {
                record.items[index].phase = .rendered
                record.items[index].message = nil
            }
        }
        if let updated { runtime.onChange(updated) }
    }

    // MARK: - Phases

    private func execute(_ id: String) async throws {
        try await change(id) { $0.status = .running; $0.pausedReason = nil }
        try await renderPhase(id)
        try await createRemote(id)
        try await uploadPhase(id)
        try await processPhase(id)
        await conclude(id)
    }

    private func renderPhase(_ id: String) async throws {
        let record = try await current(id)
        let folder = URL(fileURLWithPath: record.stagingFolderPath, isDirectory: true)
        let pending = record.items.filter { $0.phase == .queued }.sorted { $0.position < $1.position }
        guard !pending.isEmpty else { return }

        let needed = Int64(pending.count) * runtime.estimatedBytesPerPhoto
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let available = runtime.freeSpace(folder)
        guard available >= needed else {
            throw TransferError.insufficientSpace(needed: needed, available: available)
        }

        for item in pending {
            try Task.checkCancellation()
            let destination = folder.appendingPathComponent(
                String(format: "%04d-%@", item.position, Self.safeName(item.uploadFileName))
            )
            do {
                try? FileManager.default.removeItem(at: destination)   // partial leftover of an interrupted run
                try await runtime.render(item, destination, record)
                let digest = try await TransferHashing.sha256(of: destination)
                try await change(id) { record in
                    guard let index = record.items.firstIndex(where: { $0.id == item.id }) else { return }
                    record.items[index].phase = .rendered
                    record.items[index].stagedPath = destination.path
                    record.items[index].sizeBytes = Int(digest.size)
                    record.items[index].sha256 = digest.hex
                    record.items[index].message = nil
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try await change(id) { record in
                    guard let index = record.items.firstIndex(where: { $0.id == item.id }) else { return }
                    record.items[index].phase = .failed
                    record.items[index].message = "Could not prepare this photo: \(error.localizedDescription)"
                }
            }
        }
    }

    private func createRemote(_ id: String) async throws {
        let record = try await current(id)
        let sendable = record.items.filter { ($0.phase != .queued && $0.phase != .failed) || $0.remoteItemID != nil }
        guard !sendable.isEmpty else { throw TransferError.nothingToSend }
        if sendable.allSatisfy({ $0.remoteItemID != nil }) { return }

        let manifest = try sendable.sorted { $0.position < $1.position }.map { item -> StudioOSManifestItem in
            guard let size = item.sizeBytes, let hash = item.sha256 else { throw TransferError.nothingToSend }
            return StudioOSManifestItem(
                clientItemId: item.id, fileName: item.uploadFileName,
                sizeBytes: size, sha256: hash, position: item.position
            )
        }
        let remote = try await runtime.api.createTransfer(
            StudioOSCreateTransfer(clientTransferId: record.id, galleryId: record.galleryID, items: manifest)
        )
        try await change(id) { record in
            record.remoteTransferID = remote.transferId
            for remoteItem in remote.items {
                guard let index = record.items.firstIndex(where: { $0.id == remoteItem.clientItemId }) else { continue }
                record.items[index].remoteItemID = remoteItem.itemId
                record.items[index].mediaID = remoteItem.mediaId
                Self.apply(remoteItem.status, to: &record.items[index])
            }
        }
        await removeStagedFilesOfReadyItems(id)
    }

    private func uploadPhase(_ id: String) async throws {
        let record = try await current(id)
        let queue = record.items
            .filter { $0.phase == .rendered && $0.remoteItemID != nil }
            .sorted { $0.position < $1.position }
            .map(\.id)
        guard !queue.isEmpty else { return }

        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = queue.makeIterator()
            var running = 0
            while running < max(1, runtime.maxUploads), let itemID = next.next() {
                group.addTask { try await self.uploadOne(id, itemID: itemID) }
                running += 1
            }
            while try await group.next() != nil {
                if let itemID = next.next() {
                    group.addTask { try await self.uploadOne(id, itemID: itemID) }
                }
            }
        }
    }

    private func uploadOne(_ id: String, itemID: String) async throws {
        try Task.checkCancellation()
        let record = try await current(id)
        guard let item = record.items.first(where: { $0.id == itemID }),
              let remoteTransfer = record.remoteTransferID, let remoteItem = item.remoteItemID,
              let staged = item.stagedPath
        else { return }

        do {
            // An earlier run may have uploaded and then lost the reply: let the server check
            // for the object before sending the bytes again.
            if item.putStarted, let state = try await tryComplete(remoteTransfer, remoteItem) {
                try await applyRemote(id, itemID: itemID, remote: state)
                return
            }
            try await change(id) { record in
                guard let index = record.items.firstIndex(where: { $0.id == itemID }) else { return }
                record.items[index].putStarted = true
            }
            var target = try await runtime.api.uploadURL(transferID: remoteTransfer, itemID: remoteItem)
            do {
                try await runtime.api.upload(file: URL(fileURLWithPath: staged), to: target)
            } catch StudioOSError.rejected(let status, _) where status == 403 {
                // The signed URL expired: renew it once.
                target = try await runtime.api.uploadURL(transferID: remoteTransfer, itemID: remoteItem)
                try await runtime.api.upload(file: URL(fileURLWithPath: staged), to: target)
            }
            let state = try await runtime.api.complete(transferID: remoteTransfer, itemID: remoteItem)
            try await applyRemote(id, itemID: itemID, remote: state)
        } catch StudioOSError.rejected(let status, let message) where status < 500 && status != 429 {
            // The server read this photo and refused it; the rest of the batch continues.
            // Server errors (5xx) and rate limiting (429) are not about this photo: they
            // propagate so the whole run pauses with the photo still rendered.
            try await change(id) { record in
                guard let index = record.items.firstIndex(where: { $0.id == itemID }) else { return }
                record.items[index].phase = .failed
                record.items[index].message = "Studio OS refused this photo (\(status)): \(message)"
            }
        }
    }

    private func tryComplete(_ transferID: String, _ itemID: String) async throws -> StudioOSRemoteItem? {
        do {
            return try await runtime.api.complete(transferID: transferID, itemID: itemID)
        } catch StudioOSError.rejected(let status, _) where status == 400 {
            return nil   // the object is not there (or wrong): fall through to uploading
        }
    }

    private func processPhase(_ id: String) async throws {
        var rounds = 0
        while true {
            try Task.checkCancellation()
            let record = try await current(id)
            guard record.items.contains(where: { $0.phase == .processing }),
                  let remoteTransfer = record.remoteTransferID
            else { return }
            guard rounds < runtime.maxPollRounds else { throw TransferError.stillProcessing }

            let status = try await runtime.api.transferStatus(transferID: remoteTransfer)
            try await change(id) { record in
                for remoteItem in status.items {
                    guard let index = record.items.firstIndex(where: { $0.id == remoteItem.clientItemId }),
                          record.items[index].phase == .processing
                    else { continue }
                    Self.apply(remoteItem.status, to: &record.items[index])
                }
            }
            await removeStagedFilesOfReadyItems(id)
            if try await current(id).items.contains(where: { $0.phase == .processing }) {
                try await Task.sleep(for: runtime.pollInterval)
                rounds += 1
            }
        }
    }

    // MARK: - Helpers

    private func conclude(_ id: String) async {
        // Repairs a run that stopped after an item became ready but before its file was removed.
        await removeStagedFilesOfReadyItems(id)
        guard let record = await runtime.store.record(id: id) else { return }
        let failed = record.counts.failed
        if failed == 0, record.counts.ready == record.items.count {
            await finish(id, status: .completed, reason: nil)
            let folder = URL(fileURLWithPath: record.stagingFolderPath)
            if (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: folder)
            }
        } else {
            let reason = failed > 0
                ? "\(failed) photo\(failed == 1 ? "" : "s") need attention."
                : "Some photos are not finished."
            await finish(id, status: .paused, reason: reason)
        }
    }

    private func applyRemote(_ id: String, itemID: String, remote: StudioOSRemoteItem) async throws {
        try await change(id) { record in
            guard let index = record.items.firstIndex(where: { $0.id == itemID }) else { return }
            Self.apply(remote.status, to: &record.items[index])
            if remote.status != .ready, record.items[index].phase == .rendered {
                record.items[index].phase = .processing
            }
        }
        await removeStagedFilesOfReadyItems(id)
    }

    private static func apply(_ status: StudioOSRemoteStatus, to item: inout TransferItemRecord) {
        switch status {
        case .ready: item.phase = .ready; item.message = nil
        case .processing: if item.phase == .rendered { item.phase = .processing }
        case .failed:
            item.phase = .failed
            item.message = "Studio OS could not prepare a preview for this photo."
        case .pending: break
        }
    }

    /// Verified, finished outputs are deleted right away; failed or pending ones stay for retry.
    private func removeStagedFilesOfReadyItems(_ id: String) async {
        guard let record = await runtime.store.record(id: id) else { return }
        var removed: Set<String> = []
        for item in record.items where item.phase == .ready {
            guard let path = item.stagedPath else { continue }
            try? FileManager.default.removeItem(atPath: path)
            if !FileManager.default.fileExists(atPath: path) { removed.insert(path) }
        }
        guard !removed.isEmpty else { return }
        // Other uploads may have changed the record while the files were being removed, so
        // clear only the paths this call actually removed, never "every ready item".
        let paths = removed
        _ = try? await runtime.store.update(id: id) { record in
            for index in record.items.indices {
                if let path = record.items[index].stagedPath, paths.contains(path) {
                    record.items[index].stagedPath = nil
                }
            }
        }
    }

    private func current(_ id: String) async throws -> TransferRecord {
        guard let record = await runtime.store.record(id: id) else { throw CocoaError(.fileNoSuchFile) }
        return record
    }

    private func change(_ id: String, _ mutate: sending (inout TransferRecord) -> Void) async throws {
        let updated = try await runtime.store.update(id: id, mutate)
        runtime.onChange(updated)
    }

    private func finish(_ id: String, status: TransferStatus, reason: String?) async {
        if let updated = try? await runtime.store.update(id: id, { record in
            record.status = status
            record.pausedReason = reason
        }) {
            runtime.onChange(updated)
        }
    }

    private static func safeName(_ name: String) -> String {
        String(name.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" ? $0 : "_" })
    }
}
