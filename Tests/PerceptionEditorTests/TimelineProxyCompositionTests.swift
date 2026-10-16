@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import PerceptionEditor

@MainActor
struct TimelineProxyCompositionTests {
    private func fixture(_ temp: TempDirectory, _ name: String) async throws -> (MediaAsset, URL) {
        let original = try await writeTestMovie(to: temp.url.appendingPathComponent("\(name).MOV"), frames: 48)
        let proxy = try await ProxyGenerator.generate(
            source: original,
            destination: temp.url.appendingPathComponent("\(name)-proxy.mov"),
            maximumSize: CGSize(width: 320, height: 180)
        ).url
        return (MediaAsset(url: original, kind: .video, durationSeconds: 48 * 1001 / 24000.0), proxy)
    }

    private func videoSourceURLs(_ item: AVPlayerItem?) -> [URL] {
        let composition = item?.asset as? AVComposition
        let track = composition?.tracks(withMediaType: .video).first
        return track?.segments.compactMap { $0.isEmpty ? nil : $0.sourceURL } ?? []
    }

    @Test func sourceResolutionRules() {
        let asset = MediaAsset(url: URL(fileURLWithPath: "/clips/A.MOV"), kind: .video)
        let proxy = URL(fileURLWithPath: "/cache/a.mov")
        #expect(TimelineCompositionService.sourceURLs(for: asset, quality: .preview, proxyURL: proxy)
            == ClipSourceURLs(video: proxy, audio: asset.url, usesProxy: true))
        #expect(TimelineCompositionService.sourceURLs(for: asset, quality: .export, proxyURL: proxy)
            == ClipSourceURLs(video: asset.url, audio: asset.url, usesProxy: false))
        #expect(TimelineCompositionService.sourceURLs(for: asset, quality: .preview, proxyURL: nil)
            == ClipSourceURLs(video: asset.url, audio: asset.url, usesProxy: false))
    }

    @Test func previewPlaysProxyAndExportUsesOriginal() async throws {
        let temp = try TempDirectory()
        let (asset, proxy) = try await fixture(temp, "A")
        let clip = TimelineClip(assetID: asset.id, durationSeconds: 1.0)
        let service = TimelineCompositionService.shared

        let preview = await service.makePlayerItem(clips: [clip], media: [asset], proxyURLsByAssetID: [asset.id: proxy])
        #expect(videoSourceURLs(preview.playerItem) == [proxy])
        #expect(preview.usedProxyCount == 1)

        let export = await service.makePlayerItem(
            clips: [clip], media: [asset], quality: .export, proxyURLsByAssetID: [asset.id: proxy]
        )
        #expect(videoSourceURLs(export.playerItem) == [asset.url])
        #expect(export.usedProxyCount == 0)
    }

    @Test func missingProxyFileFallsBackToOriginal() async throws {
        let temp = try TempDirectory()
        let (asset, proxy) = try await fixture(temp, "A")
        try FileManager.default.removeItem(at: proxy)
        let result = await TimelineCompositionService.shared.makePlayerItem(
            clips: [TimelineClip(assetID: asset.id, durationSeconds: 1.0)],
            media: [asset],
            proxyURLsByAssetID: [asset.id: proxy]
        )
        #expect(videoSourceURLs(result.playerItem) == [asset.url])
        #expect(result.warnings.isEmpty)
    }

    @Test func mixedTimelineRendersAtProxySize() async throws {
        let temp = try TempDirectory()
        let (a, proxyA) = try await fixture(temp, "A")
        let b = MediaAsset(
            url: try await writeTestMovie(to: temp.url.appendingPathComponent("B.MOV"), frames: 48),
            kind: .video
        )
        let clips = [
            TimelineClip(assetID: a.id, timelineStartSeconds: 0, durationSeconds: 1.0),
            TimelineClip(assetID: b.id, timelineStartSeconds: 1.0, durationSeconds: 1.0)
        ]
        let result = await TimelineCompositionService.shared.makePlayerItem(
            clips: clips, media: [a, b], proxyURLsByAssetID: [a.id: proxyA]
        )
        let item = try #require(result.playerItem)
        let videoComposition = try #require(item.videoComposition)
        #expect(videoComposition.renderSize == CGSize(width: 320, height: 180))

        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.videoComposition = videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let frame = try await generator.image(at: CMTime(seconds: 1.5, preferredTimescale: 24000)).image
        #expect(frame.width == 320 && frame.height == 180, "The unproxied clip is scaled into the proxy frame")
    }
}
