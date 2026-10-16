// Tests/PerceptionEditorTests/ProxyStoreTests.swift
import Foundation
import Testing
@testable import PerceptionEditor

@MainActor
struct ProxyStoreTests {
    private func makeStore(_ temp: TempDirectory, free: Int64? = 1 << 40) throws -> ProxyStore {
        ProxyStore(
            directory: try temp.subdirectory("Proxy Cache"),
            maximumSize: CGSize(width: 320, height: 180),
            availableBytes: { _ in free }
        )
    }

    private func video(_ temp: TempDirectory, _ name: String) async throws -> MediaAsset {
        let url = try await writeTestMovie(to: temp.url.appendingPathComponent(name), frames: 24)
        return MediaAsset(url: url, kind: .video, durationSeconds: 1.0)
    }

    @Test func enqueuedVideoBecomesReadyAndNotifies() async throws {
        let temp = try TempDirectory()
        let store = try makeStore(temp)
        let asset = try await video(temp, "A.MOV")
        var notified: [UUID] = []
        store.onReady = { notified.append($0) }
        store.enqueue([asset, MediaAsset(url: temp.url.appendingPathComponent("p.jpg"), kind: .photo)])
        guard case .ready(let url) = try await waitForProxy(store, asset.id) else { Issue.record("not ready"); return }
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(store.readyURL(for: asset.id) == url)
        #expect(notified == [asset.id])
        #expect(store.statuses.count == 1, "Photos never get proxies")
    }

    @Test func movedSourceReusesProxy() async throws {
        let temp = try TempDirectory()
        let store = try makeStore(temp)
        var asset = try await video(temp, "A.MOV")
        store.enqueue([asset])
        guard case .ready(let first) = try await waitForProxy(store, asset.id) else { return }
        let stamp = try FileManager.default.attributesOfItem(atPath: first.path)[.modificationDate] as? Date

        let moved = temp.url.appendingPathComponent("moved/A.MOV")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: asset.url, to: moved)
        asset.url = moved
        store.invalidate(assetID: asset.id)
        store.enqueue([asset])
        guard case .ready(let second) = try await waitForProxy(store, asset.id) else { return }
        #expect(second == first)
        #expect(try FileManager.default.attributesOfItem(atPath: second.path)[.modificationDate] as? Date == stamp)
    }

    @Test func deletedProxyIsRegenerated() async throws {
        let temp = try TempDirectory()
        let store = try makeStore(temp)
        let asset = try await video(temp, "A.MOV")
        store.enqueue([asset])
        guard case .ready(let url) = try await waitForProxy(store, asset.id) else { return }
        try FileManager.default.removeItem(at: url)
        store.invalidate(assetID: asset.id)
        store.enqueue([asset])
        guard case .ready = try await waitForProxy(store, asset.id) else { Issue.record("not regenerated"); return }
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func insufficientSpaceFailsWithoutWriting() async throws {
        let temp = try TempDirectory()
        let store = try makeStore(temp, free: 1_000_000)
        let asset = try await video(temp, "A.MOV")
        store.enqueue([asset])
        guard case .failed(let message) = try await waitForProxy(store, asset.id) else { Issue.record("should fail"); return }
        #expect(message.contains("Not enough free space"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).isEmpty)
    }

    @Test func prioritizedAssetsRunFirstAndCancelAllStopsTheQueue() async throws {
        let temp = try TempDirectory()
        let store = try makeStore(temp)
        let a = try await video(temp, "A.MOV")
        let b = try await video(temp, "B.MOV")
        var order: [UUID] = []
        store.onReady = { order.append($0) }
        store.enqueue([a, b], prioritized: [b.id])
        guard case .ready = try await waitForProxy(store, b.id) else { return }
        #expect(order.first == b.id, "Timeline clips are generated before the rest of the library")
        store.cancelAll()
        #expect(store.statuses[a.id] != .queued)
        if case .generating = store.statuses[a.id] { Issue.record("cancelAll must stop the running job") }
        try await Task.sleep(for: .milliseconds(200))
        let partials = try FileManager.default.contentsOfDirectory(atPath: store.directory.path).filter { $0.hasSuffix(".partial.mov") }
        #expect(partials.isEmpty)
    }

    @Test func unreadableVideoFailsWithReason() async throws {
        let temp = try TempDirectory()
        let store = try makeStore(temp)
        let junk = MediaAsset(url: try temp.file("bad.MOV", bytes: 4096, seed: 9), kind: .video, durationSeconds: 1)
        store.enqueue([junk])
        guard case .failed = try await waitForProxy(store, junk.id) else { Issue.record("should fail"); return }
    }
}
