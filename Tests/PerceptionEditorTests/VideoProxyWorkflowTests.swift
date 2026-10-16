@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import PerceptionEditor

@MainActor
struct VideoProxyWorkflowTests {
    private func makeStore(_ temp: TempDirectory) throws -> EditorStore {
        let suite = "pme-proxy-tests-\(UUID().uuidString)"
        return EditorStore(
            presetRepository: UserPresetRepository(defaults: UserDefaults(suiteName: suite)!),
            proxyStore: ProxyStore(
                directory: try temp.subdirectory("Proxy Cache"),
                maximumSize: CGSize(width: 320, height: 180),
                availableBytes: { _ in 1 << 40 }
            ),
            proxyDefaults: UserDefaults(suiteName: suite)!
        )
    }

    @Test func importedVideoGetsAProxyAndTheTimelinePlaysIt() async throws {
        let temp = try TempDirectory()
        let store = try makeStore(temp)
        let movie = try await writeTestMovie(to: temp.url.appendingPathComponent("A.MOV"), frames: 48)
        await store.importURLs([movie]).value
        let asset = try #require(store.project.media.first)
        guard case .ready(let proxy) = try await waitForProxy(store.proxyStore, asset.id) else { return }

        store.addToTimeline(asset)
        try await waitUntil { store.timelineUsedProxyCount == 1 }
        let composition = try #require(store.videoPlayer?.currentItem?.asset as? AVComposition)
        #expect(composition.tracks(withMediaType: .video).first?.segments.first?.sourceURL == proxy)
    }

    @Test func turningProxiesOffPlaysOriginals() async throws {
        let temp = try TempDirectory()
        let store = try makeStore(temp)
        let movie = try await writeTestMovie(to: temp.url.appendingPathComponent("A.MOV"), frames: 48)
        await store.importURLs([movie]).value
        let asset = try #require(store.project.media.first)
        _ = try await waitForProxy(store.proxyStore, asset.id)
        store.addToTimeline(asset)
        try await waitUntil { store.timelineUsedProxyCount == 1 }

        store.usesProxiesForPlayback = false
        try await waitUntil { store.timelineUsedProxyCount == 0 && store.videoPlayer?.currentItem != nil }
        let composition = try #require(store.videoPlayer?.currentItem?.asset as? AVComposition)
        #expect(composition.tracks(withMediaType: .video).first?.segments.first?.sourceURL == movie)
    }

    @Test func proxyReadyRebuildKeepsPosition() async throws {
        let temp = try TempDirectory()
        let store = try makeStore(temp)
        let movie = try await writeTestMovie(to: temp.url.appendingPathComponent("A.MOV"), frames: 96)
        await store.importURLs([movie]).value
        let asset = try #require(store.project.media.first)
        store.proxyStore.cancelAll() // Build the timeline from the original first.
        store.addToTimeline(asset)
        // Import already shows the source video, so wait for the timeline player itself.
        try await waitUntil { store.isTimelinePlayback && store.timelinePlaybackDurationSeconds > 2 }
        store.seekTimeline(to: 2.0)

        store.proxyStore.invalidate(assetID: asset.id)
        store.proxyStore.enqueue([asset])
        _ = try await waitForProxy(store.proxyStore, asset.id)
        try await waitUntil { store.timelineUsedProxyCount == 1 }
        #expect(abs(store.timelinePlaybackPositionSeconds - 2.0) < 0.1)
    }

    @Test func proxyReadyRebuildKeepsPlayState() async throws {
        let temp = try TempDirectory()
        let store = try makeStore(temp)
        let movie = try await writeTestMovie(to: temp.url.appendingPathComponent("A.MOV"), frames: 240)
        await store.importURLs([movie]).value
        let asset = try #require(store.project.media.first)
        store.proxyStore.cancelAll()
        store.addToTimeline(asset)
        try await waitUntil { store.isTimelinePlayback && store.timelinePlaybackDurationSeconds > 2 }
        store.seekTimeline(to: 2.0)
        store.toggleVideoPlayback()
        try await waitUntil { store.isVideoPlaying }
        let before = try #require(store.videoPlayer)

        store.proxyStore.invalidate(assetID: asset.id)
        store.proxyStore.enqueue([asset])
        _ = try await waitForProxy(store.proxyStore, asset.id)
        try await waitUntil { store.timelineUsedProxyCount == 1 && store.videoPlayer !== before }
        try await waitUntil { store.isVideoPlaying }
        #expect(store.isTimelinePlayback)
        #expect(store.timelinePlaybackPositionSeconds >= 1.9)
    }

    @Test func progressTicksDoNotFanOutToEditorObservers() async throws {
        let temp = try TempDirectory()
        let store = try makeStore(temp)
        let movie = try await writeTestMovie(to: temp.url.appendingPathComponent("A.MOV"), frames: 240)
        // No import: that would start a player whose 100 ms monitor publishes on its own.
        let asset = MediaAsset(url: movie, kind: .video, durationSeconds: 10)
        store.project.media.append(asset)
        var emissions = 0
        let cancellable = store.objectWillChange.sink { emissions += 1 }
        store.proxyStore.enqueue([asset])
        _ = try await waitForProxy(store.proxyStore, asset.id)
        try await Task.sleep(for: .milliseconds(200))
        cancellable.cancel()
        // queued, generating, ready (plus the source refresh on ready); per-percent fan-out is ~100.
        #expect(emissions <= 10, "Got \(emissions) emissions")
    }

    @Test func backgroundProxyNeverSwitchesViewerToTimelineMode() async throws {
        let temp = try TempDirectory()
        let store = try makeStore(temp)
        let a = try await writeTestMovie(to: temp.url.appendingPathComponent("A.MOV"), frames: 48)
        let b = try await writeTestMovie(to: temp.url.appendingPathComponent("B.MOV"), frames: 48)
        await store.importURLs([a, b]).value
        store.proxyStore.cancelAll()
        let assetA = try #require(store.project.media.first { $0.url == a })
        let assetB = try #require(store.project.media.first { $0.url == b })
        store.proxyStore.invalidate(assetID: assetA.id)
        store.proxyStore.invalidate(assetID: assetB.id)
        store.addToTimeline(assetB)
        try await waitUntil { store.isTimelinePlayback && store.timelinePlaybackDurationSeconds > 0 }
        store.selectVideo(assetA) // Viewer now shows the source clip, not the timeline.
        #expect(!store.isTimelinePlayback)
        let player = try #require(store.videoPlayer)

        store.proxyStore.enqueue([assetB])
        _ = try await waitForProxy(store.proxyStore, assetB.id)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!store.isTimelinePlayback)
        #expect(store.videoPlayer === player)
    }

    @Test func deletedProxyIsRegeneratedWhenTheTimelineRebuilds() async throws {
        let temp = try TempDirectory()
        let store = try makeStore(temp)
        let movie = try await writeTestMovie(to: temp.url.appendingPathComponent("A.MOV"), frames: 48)
        await store.importURLs([movie]).value
        let asset = try #require(store.project.media.first)
        guard case .ready(let proxy) = try await waitForProxy(store.proxyStore, asset.id) else { return }
        store.addToTimeline(asset)
        try await waitUntil { store.timelineUsedProxyCount == 1 }

        try FileManager.default.removeItem(at: proxy) // The user cleared the cache folder.
        store.updateSelectedAudioAdjustments { $0.volume = 0.5 } // Any edit rebuilds the timeline.
        try await waitUntil { FileManager.default.fileExists(atPath: proxy.path) }
        #expect(store.proxyStore.readyURL(for: asset.id) == proxy)
        try await waitUntil { store.timelineUsedProxyCount == 1 }
    }

    @Test func deletedProxyIsRegeneratedWhenTheSourceViewerOpensIt() async throws {
        let temp = try TempDirectory()
        let store = try makeStore(temp)
        let movie = try await writeTestMovie(to: temp.url.appendingPathComponent("A.MOV"), frames: 48)
        await store.importURLs([movie]).value
        let asset = try #require(store.project.media.first)
        guard case .ready(let proxy) = try await waitForProxy(store.proxyStore, asset.id) else { return }

        try FileManager.default.removeItem(at: proxy)
        store.selectVideo(asset)
        try await waitUntil { FileManager.default.fileExists(atPath: proxy.path) }
        #expect(store.proxyStore.readyURL(for: asset.id) == proxy)
    }

    @Test func newProjectForgetsTheOldProjectsProxyStatuses() async throws {
        let temp = try TempDirectory()
        let store = try makeStore(temp)
        let movie = try await writeTestMovie(to: temp.url.appendingPathComponent("A.MOV"), frames: 48)
        await store.importURLs([movie]).value
        let asset = try #require(store.project.media.first)
        _ = try await waitForProxy(store.proxyStore, asset.id)
        store.resetToEmptyProject(named: "Next")
        #expect(store.proxyStore.statuses.isEmpty)
    }

    @Test func newProjectCancelsPendingProxies() async throws {
        let temp = try TempDirectory()
        let store = try makeStore(temp)
        let movie = try await writeTestMovie(to: temp.url.appendingPathComponent("A.MOV"), frames: 480, width: 1920, height: 1080)
        await store.importURLs([movie]).value
        store.resetToEmptyProject(named: "Next")
        #expect(!store.proxyStore.statuses.values.contains { if case .generating = $0 { true } else { $0 == .queued } })
    }
}

@MainActor
func waitUntil(timeout: Duration = .seconds(30), _ condition: () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        guard clock.now < deadline else { Issue.record("Condition not met within \(timeout)"); return }
        try await Task.sleep(for: .milliseconds(20))
    }
}
