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
        let movie = try await writeTestMovie(to: temp.url.appendingPathComponent("A.MOV"), frames: 48, width: 160, height: 90)
        await store.importURLs([movie]).value
        let asset = try #require(store.project.media.first)
        guard case .ready(let proxy) = try await waitForProxy(store.proxyStore, asset.id) else { return }

        store.addToTimeline(asset)
        try await waitUntil { store.timelineUsedProxyCount == 1 }
        let composition = try #require(store.videoPlayer?.currentItem?.asset as? AVComposition)
        #expect(composition.tracks(withMediaType: .video).first?.segments.first?.sourceURL == proxy)
    }

    /// The source viewer shows log footage through its input transform: an Apple Log clip plays through
    /// the compositor, while an ordinary clip with no color work still plays natively.
    @Test func sourceViewerShowsLogThroughTheCompositorAndPlainClipsNatively() async throws {
        let temp = try TempDirectory()
        let store = try makeStore(temp)
        let log = try await writeVideoRangeLogTestMovie(to: temp.url.appendingPathComponent("IMG_LOG.MOV"), frames: 12, width: 160, height: 90)
        let plain = try await writeTestMovie(to: temp.url.appendingPathComponent("PLAIN.MOV"), frames: 12, width: 160, height: 90)
        store.usesProxiesForPlayback = false
        await store.importURLs([log, plain]).value
        let logAsset = try #require(store.project.media.first { $0.filename == "IMG_LOG.MOV" })
        let plainAsset = try #require(store.project.media.first { $0.filename == "PLAIN.MOV" })
        try #require(logAsset.sourceColor?.transfer == .appleLog)

        store.selectVideo(logAsset)
        try await waitUntil { store.videoPlayer?.currentItem?.videoComposition != nil }
        #expect(store.videoPlayer?.currentItem?.videoComposition?.customVideoCompositorClass != nil)

        store.selectVideo(plainAsset)
        try await waitUntil { store.videoPlayer?.currentItem?.videoComposition == nil && store.videoPlayer?.currentItem != nil }
        #expect(store.videoPlayer?.currentItem?.videoComposition == nil)
    }

    @Test func turningProxiesOffPlaysOriginals() async throws {
        let temp = try TempDirectory()
        let store = try makeStore(temp)
        let movie = try await writeTestMovie(to: temp.url.appendingPathComponent("A.MOV"), frames: 48, width: 160, height: 90)
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
        let movie = try await writeTestMovie(to: temp.url.appendingPathComponent("A.MOV"), frames: 96, width: 160, height: 90)
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
        let movie = try await writeTestMovie(to: temp.url.appendingPathComponent("A.MOV"), frames: 240, width: 160, height: 90)
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
        let movie = try await writeTestMovie(to: temp.url.appendingPathComponent("A.MOV"), frames: 240, width: 160, height: 90)
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
        let a = try await writeTestMovie(to: temp.url.appendingPathComponent("A.MOV"), frames: 48, width: 160, height: 90)
        let b = try await writeTestMovie(to: temp.url.appendingPathComponent("B.MOV"), frames: 48, width: 160, height: 90)
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
        let movie = try await writeTestMovie(to: temp.url.appendingPathComponent("A.MOV"), frames: 48, width: 160, height: 90)
        await store.importURLs([movie]).value
        let asset = try #require(store.project.media.first)
        guard case .ready(let proxy) = try await waitForProxy(store.proxyStore, asset.id) else { return }
        store.addToTimeline(asset)
        try await waitUntil { store.timelineUsedProxyCount == 1 }

        try FileManager.default.removeItem(at: proxy) // The user cleared the cache folder.
        store.updateSelectedAudioAdjustments { $0.volume = 0.5 } // Any edit rebuilds the timeline.
        // The file is published before the main actor marks it ready.
        try await waitUntil {
            FileManager.default.fileExists(atPath: proxy.path) && store.proxyStore.readyURL(for: asset.id) == proxy
        }
        #expect(store.proxyStore.readyURL(for: asset.id) == proxy)
        try await waitUntil { store.timelineUsedProxyCount == 1 }
    }

    @Test func deletedProxyIsRegeneratedWhenTheSourceViewerOpensIt() async throws {
        let temp = try TempDirectory()
        let store = try makeStore(temp)
        let movie = try await writeTestMovie(to: temp.url.appendingPathComponent("A.MOV"), frames: 48, width: 160, height: 90)
        await store.importURLs([movie]).value
        let asset = try #require(store.project.media.first)
        guard case .ready(let proxy) = try await waitForProxy(store.proxyStore, asset.id) else { return }

        try FileManager.default.removeItem(at: proxy)
        store.selectVideo(asset)
        // The file is published before the main actor marks it ready.
        try await waitUntil {
            FileManager.default.fileExists(atPath: proxy.path) && store.proxyStore.readyURL(for: asset.id) == proxy
        }
        #expect(store.proxyStore.readyURL(for: asset.id) == proxy)
    }

    @Test func newProjectForgetsTheOldProjectsProxyStatuses() async throws {
        let temp = try TempDirectory()
        let store = try makeStore(temp)
        let movie = try await writeTestMovie(to: temp.url.appendingPathComponent("A.MOV"), frames: 48, width: 160, height: 90)
        await store.importURLs([movie]).value
        let asset = try #require(store.project.media.first)
        _ = try await waitForProxy(store.proxyStore, asset.id)
        store.resetToEmptyProject(named: "Next")
        #expect(store.proxyStore.statuses.isEmpty)
    }

    private func sourceComposition(_ store: EditorStore) -> AVComposition? {
        store.videoPlayer?.currentItem?.asset as? AVComposition
    }

    private func segmentURLs(_ composition: AVComposition?, _ type: AVMediaType) -> [URL] {
        composition?.tracks(withMediaType: type).flatMap(\.segments).compactMap { $0.isEmpty ? nil : $0.sourceURL } ?? []
    }

    /// Proxies are video-only; the source viewer must still play the original's sound.
    @Test func sourceViewerPlaysProxyVideoWithOriginalAudio() async throws {
        let temp = try TempDirectory()
        let store = try makeStore(temp)
        let movie = try await writeTestMovie(to: temp.url.appendingPathComponent("A.MOV"), frames: 48, width: 160, height: 90, withAudio: true)
        await store.importURLs([movie]).value
        let asset = try #require(store.project.media.first)
        guard case .ready(let proxy) = try await waitForProxy(store.proxyStore, asset.id) else { return }

        try await waitUntil { segmentURLs(sourceComposition(store), .video) == [proxy] }
        #expect(!store.isTimelinePlayback)
        #expect(segmentURLs(sourceComposition(store), .video) == [proxy], "Video comes from the proxy")
        #expect(segmentURLs(sourceComposition(store), .audio) == [movie], "Audio comes from the original")

        store.usesProxiesForPlayback = false
        try await waitUntil { (store.videoPlayer?.currentItem?.asset as? AVURLAsset)?.url == movie }
        #expect(!store.isTimelinePlayback)
    }

    @Test func sourceViewerKeepsPositionWhenItsProxyBecomesReady() async throws {
        let temp = try TempDirectory()
        let store = try makeStore(temp)
        let movie = try await writeTestMovie(to: temp.url.appendingPathComponent("A.MOV"), frames: 96, width: 160, height: 90, withAudio: true)
        await store.importURLs([movie]).value
        let asset = try #require(store.project.media.first)
        store.proxyStore.cancelAll()
        store.proxyStore.invalidate(assetID: asset.id)
        store.selectVideo(asset)
        let original = try #require(store.videoPlayer)
        try await waitUntil { original.currentItem?.status == .readyToPlay }
        await original.seek(to: CMTime(seconds: 2, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)

        store.proxyStore.enqueue([asset])
        guard case .ready(let proxy) = try await waitForProxy(store.proxyStore, asset.id) else { return }
        try await waitUntil { store.videoPlayer !== original && segmentURLs(sourceComposition(store), .video) == [proxy] }
        let swapped = try #require(store.videoPlayer)
        try await waitUntil { abs(swapped.currentTime().seconds - 2) < 0.05 }
        #expect(abs(swapped.currentTime().seconds - 2) < 0.05, "Paused clip jumped to \(swapped.currentTime().seconds)")
        #expect(!store.isVideoPlaying)
    }

    @Test func togglingProxiesKeepsSourcePlaybackRunning() async throws {
        let temp = try TempDirectory()
        let store = try makeStore(temp)
        let movie = try await writeTestMovie(to: temp.url.appendingPathComponent("A.MOV"), frames: 240, width: 160, height: 90, withAudio: true)
        await store.importURLs([movie]).value
        let asset = try #require(store.project.media.first)
        guard case .ready(let proxy) = try await waitForProxy(store.proxyStore, asset.id) else { return }
        try await waitUntil { segmentURLs(sourceComposition(store), .video) == [proxy] }
        let before = try #require(store.videoPlayer)
        try await waitUntil { before.currentItem?.status == .readyToPlay }
        await before.seek(to: CMTime(seconds: 3, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        store.toggleVideoPlayback()
        try await waitUntil { store.isVideoPlaying }

        store.usesProxiesForPlayback = false
        try await waitUntil { store.videoPlayer !== before }
        let after = try #require(store.videoPlayer)
        try await waitUntil { store.isVideoPlaying }
        #expect(after.currentTime().seconds >= 2.9, "Playback restarted at \(after.currentTime().seconds)")
    }

    @Test func newProjectCancelsPendingProxies() async throws {
        let temp = try TempDirectory()
        let store = try makeStore(temp)
        let movie = try await writeTestMovie(to: temp.url.appendingPathComponent("A.MOV"), frames: 240, width: 160, height: 90)
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
