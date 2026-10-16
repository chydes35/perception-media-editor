@preconcurrency import AVFoundation
import CoreImage
import Foundation

struct TimelineCompositionResult {
    var playerItem: AVPlayerItem?
    var durationSeconds: Double
    var insertedClipIDs: [UUID]
    var warnings: [String]
    var usedProxyCount = 0
}

enum MediaQuality: Sendable {
    /// Editing playback. Uses a ready proxy when one exists.
    case preview
    /// Deliverables. Always reads camera originals.
    case export
}

struct ClipSourceURLs: Equatable, Sendable {
    var video: URL
    var audio: URL
    var usesProxy: Bool
}

private struct TimelineColorSegment: Sendable {
    var startSeconds: Double
    var durationSeconds: Double
    var adjustments: PhotoAdjustments

    func contains(_ seconds: Double) -> Bool {
        seconds >= startSeconds && seconds < startSeconds + durationSeconds
    }
}

private struct TimelineAudioSegment: Sendable {
    var startSeconds: Double
    var durationSeconds: Double
    var adjustments: ClipAudioAdjustments
}

private struct SendableVideoComposition: @unchecked Sendable {
    let value: AVVideoComposition?
}

@MainActor
final class TimelineCompositionService {
    static let shared = TimelineCompositionService()

    private init() {}

    /// Proxies are video-only, so audio always comes from the original. A proxy URL whose file
    /// has gone (the cache was cleared) falls back to the original without a warning.
    nonisolated static func sourceURLs(for asset: MediaAsset, quality: MediaQuality, proxyURL: URL?) -> ClipSourceURLs {
        guard quality == .preview, let proxyURL else {
            return ClipSourceURLs(video: asset.url, audio: asset.url, usesProxy: false)
        }
        return ClipSourceURLs(video: proxyURL, audio: asset.url, usesProxy: true)
    }

    /// `quality` has no default: a caller that renders deliverables must say `.export` explicitly
    /// rather than silently inheriting proxies.
    func makePlayerItem(
        clips: [TimelineClip],
        media: [MediaAsset],
        adjustmentsByClipID: [UUID: PhotoAdjustments] = [:],
        audioAdjustmentsByClipID: [UUID: ClipAudioAdjustments] = [:],
        quality: MediaQuality,
        proxyURLsByAssetID: [UUID: URL] = [:]
    ) async -> TimelineCompositionResult {
        let composition = AVMutableComposition()
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            return TimelineCompositionResult(
                playerItem: nil,
                durationSeconds: 0,
                insertedClipIDs: [],
                warnings: ["The video composition track could not be created."],
                usedProxyCount: 0
            )
        }

        let compositionAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )
        let assetsByID = Dictionary(uniqueKeysWithValues: media.map { ($0.id, $0) })
        let orderedClips = clips
            .filter(\.isEnabled)
            .sorted { $0.timelineStartSeconds < $1.timelineStartSeconds }

        var insertedClipIDs: [UUID] = []
        var colorSegments: [TimelineColorSegment] = []
        var audioSegments: [TimelineAudioSegment] = []
        var warnings: [String] = []
        var didSetVideoTransform = false
        var usedProxyCount = 0
        var proxyRenderSize: CGSize?

        for clip in orderedClips {
            if Task.isCancelled { break }

            guard let mediaAsset = assetsByID[clip.assetID] else {
                warnings.append("Skipped a clip whose source is no longer in the project.")
                continue
            }
            guard FileManager.default.fileExists(atPath: mediaAsset.url.path) else {
                warnings.append("Skipped missing media: \(mediaAsset.filename)")
                continue
            }

            let proxyURL = proxyURLsByAssetID[clip.assetID]
                .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            let sources = Self.sourceURLs(for: mediaAsset, quality: quality, proxyURL: proxyURL)
            let sourceAsset = AVURLAsset(url: sources.video)
            let audioAsset = sources.audio == sources.video ? sourceAsset : AVURLAsset(url: sources.audio)
            guard let assetDuration = try? await sourceAsset.load(.duration) else {
                warnings.append("Skipped unreadable media: \(mediaAsset.filename)")
                continue
            }
            guard let sourceVideoTrack = (try? await sourceAsset.loadTracks(withMediaType: .video))?.first else {
                warnings.append("Skipped media without a video track: \(mediaAsset.filename)")
                continue
            }

            let sourceStartSeconds = max(0, clip.sourceStartSeconds)
            let availableSeconds = max(0, assetDuration.seconds - sourceStartSeconds)
            let insertedDurationSeconds = min(clip.durationSeconds, availableSeconds)
            guard insertedDurationSeconds > 0 else {
                warnings.append("Skipped an empty clip: \(mediaAsset.filename)")
                continue
            }

            let sourceRange = CMTimeRange(
                start: CMTime(seconds: sourceStartSeconds, preferredTimescale: 600),
                duration: CMTime(seconds: insertedDurationSeconds, preferredTimescale: 600)
            )
            let insertionTime = CMTime(
                seconds: max(0, clip.timelineStartSeconds),
                preferredTimescale: 600
            )

            do {
                try compositionVideoTrack.insertTimeRange(
                    sourceRange,
                    of: sourceVideoTrack,
                    at: insertionTime
                )
            } catch {
                warnings.append("Skipped incompatible video: \(mediaAsset.filename)")
                continue
            }

            if sources.usesProxy {
                usedProxyCount += 1
                if proxyRenderSize == nil, let size = try? await sourceVideoTrack.load(.naturalSize) {
                    // The composition track carries the preferred transform, so frames reach the
                    // CI handler upright; the render size must be the post-transform size.
                    let transform = (try? await sourceVideoTrack.load(.preferredTransform)) ?? .identity
                    let upright = size.applying(transform)
                    proxyRenderSize = CGSize(width: abs(upright.width), height: abs(upright.height))
                }
            }

            if !didSetVideoTransform,
               let preferredTransform = try? await sourceVideoTrack.load(.preferredTransform) {
                compositionVideoTrack.preferredTransform = preferredTransform
                didSetVideoTransform = true
            }

            if !clip.isMuted,
               let compositionAudioTrack,
               let sourceAudioTrack = (try? await audioAsset.loadTracks(withMediaType: .audio))?.first {
                do {
                    try compositionAudioTrack.insertTimeRange(
                        sourceRange,
                        of: sourceAudioTrack,
                        at: insertionTime
                    )
                    audioSegments.append(
                        TimelineAudioSegment(
                            startSeconds: max(0, clip.timelineStartSeconds),
                            durationSeconds: insertedDurationSeconds,
                            adjustments: audioAdjustmentsByClipID[clip.id] ?? .neutral
                        )
                    )
                } catch {
                    warnings.append("Video inserted without audio: \(mediaAsset.filename)")
                }
            }

            insertedClipIDs.append(clip.id)
            colorSegments.append(
                TimelineColorSegment(
                    startSeconds: max(0, clip.timelineStartSeconds),
                    durationSeconds: insertedDurationSeconds,
                    adjustments: adjustmentsByClipID[clip.id] ?? .neutral
                )
            )
        }

        guard !insertedClipIDs.isEmpty else {
            return TimelineCompositionResult(
                playerItem: nil,
                durationSeconds: 0,
                insertedClipIDs: [],
                warnings: warnings.isEmpty ? ["The timeline has no playable clips."] : warnings,
                usedProxyCount: 0
            )
        }

        let durationSeconds = composition.duration.seconds
        let playerItem = AVPlayerItem(asset: composition)
        if let compositionAudioTrack, !audioSegments.isEmpty {
            let audioParameters = AVMutableAudioMixInputParameters(track: compositionAudioTrack)
            for segment in audioSegments {
                let volume = Float(min(1, max(0, segment.adjustments.volume)))
                let maximumFade = max(0, segment.durationSeconds / 2)
                let fadeIn = min(maximumFade, max(0, segment.adjustments.fadeInSeconds))
                let fadeOut = min(maximumFade, max(0, segment.adjustments.fadeOutSeconds))
                let start = CMTime(seconds: segment.startSeconds, preferredTimescale: 600)

                if fadeIn > 0 {
                    audioParameters.setVolumeRamp(
                        fromStartVolume: 0,
                        toEndVolume: volume,
                        timeRange: CMTimeRange(
                            start: start,
                            duration: CMTime(seconds: fadeIn, preferredTimescale: 600)
                        )
                    )
                } else {
                    audioParameters.setVolume(volume, at: start)
                }

                if fadeOut > 0 {
                    let fadeStart = CMTime(
                        seconds: segment.startSeconds + segment.durationSeconds - fadeOut,
                        preferredTimescale: 600
                    )
                    audioParameters.setVolume(volume, at: fadeStart)
                    audioParameters.setVolumeRamp(
                        fromStartVolume: volume,
                        toEndVolume: 0,
                        timeRange: CMTimeRange(
                            start: fadeStart,
                            duration: CMTime(seconds: fadeOut, preferredTimescale: 600)
                        )
                    )
                }
            }
            let audioMix = AVMutableAudioMix()
            audioMix.inputParameters = [audioParameters]
            playerItem.audioMix = audioMix
        }

        let needsColor = colorSegments.contains(where: { $0.adjustments != .neutral })
        if needsColor || proxyRenderSize != nil {
            let renderSize = proxyRenderSize
            let renderSegments = colorSegments
            let videoCompositionResult: SendableVideoComposition = await withCheckedContinuation { continuation in
                AVVideoComposition.videoComposition(
                    with: composition,
                    applyingCIFiltersWithHandler: { request in
                        let seconds = request.compositionTime.seconds
                        let adjustments = renderSegments.first(where: { $0.contains(seconds) })?.adjustments
                            ?? .neutral
                        var source = request.sourceImage
                        if let renderSize, source.extent.size != renderSize {
                            let scale = min(renderSize.width / source.extent.width, renderSize.height / source.extent.height)
                            source = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                            let dx = (renderSize.width - source.extent.width) / 2 - source.extent.minX
                            let dy = (renderSize.height - source.extent.height) / 2 - source.extent.minY
                            source = source.transformed(by: CGAffineTransform(translationX: dx, y: dy))
                                .composited(over: CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: renderSize)))
                        }
                        // A neutral clip only needs fitting into the proxy frame; skip the colour chain.
                        let output = adjustments == .neutral
                            ? source
                            : MediaColorRenderer.render(source, adjustments: adjustments, includesGeometry: false)
                        request.finish(
                            with: output.cropped(to: CGRect(origin: .zero, size: renderSize ?? request.sourceImage.extent.size)),
                            context: nil
                        )
                    },
                    completionHandler: { videoComposition, _ in
                        continuation.resume(returning: SendableVideoComposition(value: videoComposition))
                    }
                )
            }
            if let videoComposition = videoCompositionResult.value {
                if let renderSize, let mutable = videoComposition.mutableCopy() as? AVMutableVideoComposition {
                    mutable.renderSize = renderSize
                    playerItem.videoComposition = mutable
                } else {
                    playerItem.videoComposition = videoComposition
                }
            } else {
                warnings.append("Clip color could not be previewed.")
            }
        }

        return TimelineCompositionResult(
            playerItem: playerItem,
            durationSeconds: durationSeconds.isFinite ? max(0, durationSeconds) : 0,
            insertedClipIDs: insertedClipIDs,
            warnings: warnings,
            usedProxyCount: usedProxyCount
        )
    }
}
