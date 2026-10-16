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

/// Segments are exact `CMTimeRange`s built from frames, so a frame on a cut belongs to exactly one clip.
private struct TimelineColorSegment: Sendable {
    var range: CMTimeRange
    var adjustments: PhotoAdjustments
}

private struct TimelineAudioSegment: Sendable {
    var range: CMTimeRange
    var adjustments: ClipAudioAdjustments
}

private struct SendableVideoComposition: @unchecked Sendable {
    let value: AVVideoComposition?
}

@MainActor
final class TimelineCompositionService {
    static let shared = TimelineCompositionService()

    private init() {}

    nonisolated static let mixedRateWarning =
        "Clips with a different frame rate from the first clip are fitted to whole frames of the timeline's rate."

    /// Proxies are video-only, so audio always comes from the original. A proxy URL whose file
    /// has gone (the cache was cleared) falls back to the original without a warning.
    nonisolated static func sourceURLs(for asset: MediaAsset, quality: MediaQuality, proxyURL: URL?) -> ClipSourceURLs {
        guard quality == .preview, let proxyURL else {
            return ClipSourceURLs(video: asset.url, audio: asset.url, usesProxy: false)
        }
        return ClipSourceURLs(video: proxyURL, audio: asset.url, usesProxy: true)
    }

    /// The source viewer's item. Proxies are video-only, so with a usable proxy this is a one-clip
    /// composition of the proxy's video and the original's audio; otherwise it is simply the original.
    func makeSourcePlayerItem(for asset: MediaAsset, proxyURL: URL?) async -> AVPlayerItem {
        let usableProxy = proxyURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        let sources = Self.sourceURLs(for: asset, quality: .preview, proxyURL: usableProxy)
        guard sources.usesProxy else { return AVPlayerItem(url: asset.url) }

        let videoAsset = AVURLAsset(url: sources.video)
        let composition = AVMutableComposition()
        guard let videoTrack = (try? await videoAsset.loadTracks(withMediaType: .video))?.first,
              let duration = try? await videoAsset.load(.duration), duration > .zero,
              let compositionVideo = composition.addMutableTrack(
                  withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
              )
        else { return AVPlayerItem(url: asset.url) }
        let range = CMTimeRange(start: .zero, duration: duration)
        do { try compositionVideo.insertTimeRange(range, of: videoTrack, at: .zero) } catch {
            return AVPlayerItem(url: asset.url)
        }
        compositionVideo.preferredTransform = (try? await videoTrack.load(.preferredTransform)) ?? .identity

        let audioAsset = AVURLAsset(url: sources.audio)
        if let audioTrack = (try? await audioAsset.loadTracks(withMediaType: .audio))?.first,
           let audioRange = try? await audioTrack.load(.timeRange),
           let compositionAudio = composition.addMutableTrack(
               withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            let overlap = range.intersection(audioRange)
            if overlap.duration > .zero {
                try? compositionAudio.insertTimeRange(overlap, of: audioTrack, at: overlap.start)
            }
        }
        return AVPlayerItem(asset: composition)
    }

    /// `quality` has no default: a caller that renders deliverables must say `.export` explicitly
    /// rather than silently inheriting proxies. Clip positions are frames in `sequenceFrameRate`
    /// (by default the first clip's rate), and every time is built exactly from frames.
    func makePlayerItem(
        clips: [TimelineClip],
        media: [MediaAsset],
        adjustmentsByClipID: [UUID: PhotoAdjustments] = [:],
        audioAdjustmentsByClipID: [UUID: ClipAudioAdjustments] = [:],
        quality: MediaQuality,
        proxyURLsByAssetID: [UUID: URL] = [:],
        sequenceFrameRate: FrameRate? = nil
    ) async -> TimelineCompositionResult {
        let sequenceRate = sequenceFrameRate ?? clips.first?.frameRate ?? .ntsc23976
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
        // The default track timescale (600) cannot hold 1001/24000 frame times, so it rounded every
        // source frame and the player showed the previous frame at some times.
        compositionVideoTrack.naturalTimeScale = sequenceRate.timescale
        compositionAudioTrack?.naturalTimeScale = sequenceRate.timescale
        let assetsByID = Dictionary(uniqueKeysWithValues: media.map { ($0.id, $0) })
        let orderedClips = clips
            .filter(\.isEnabled)
            .sorted { $0.timelineStartFrame < $1.timelineStartFrame }

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
            guard let sourceVideoTrack = (try? await sourceAsset.loadTracks(withMediaType: .video))?.first else {
                warnings.append("Skipped media without a video track: \(mediaAsset.filename)")
                continue
            }
            guard let trackRange = try? await sourceVideoTrack.load(.timeRange) else {
                warnings.append("Skipped unreadable media: \(mediaAsset.filename)")
                continue
            }

            // Frames count from the track's first frame (proxies keep the original's first timestamp).
            let rate = clip.frameRate
            let sourceStartFrame = max(0, clip.sourceStartFrame)
            let availableFrames = max(0, rate.frame(containing: trackRange.end, origin: trackRange.start) - sourceStartFrame)
            let insertedFrames = min(clip.durationFrames, availableFrames)
            guard insertedFrames > 0 else {
                warnings.append("Skipped an empty clip: \(mediaAsset.filename)")
                continue
            }
            if rate != sequenceRate, !warnings.contains(Self.mixedRateWarning) {
                warnings.append(Self.mixedRateWarning)
            }

            // A clip in another rate fills whole sequence frames; its source is cut to that slot.
            let slot = CMTimeRange(
                start: sequenceRate.time(ofFrame: max(0, clip.timelineStartFrame)),
                duration: sequenceRate.time(ofFrame: rate.frames(insertedFrames, in: sequenceRate))
            )
            let sourceRange = CMTimeRange(
                start: rate.time(ofFrame: sourceStartFrame, origin: trackRange.start),
                duration: CMTimeMinimum(rate.time(ofFrame: insertedFrames), slot.duration)
            )
            let insertionTime = slot.start

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
                        TimelineAudioSegment(range: slot, adjustments: audioAdjustmentsByClipID[clip.id] ?? .neutral)
                    )
                } catch {
                    warnings.append("Video inserted without audio: \(mediaAsset.filename)")
                }
            }

            insertedClipIDs.append(clip.id)
            colorSegments.append(
                TimelineColorSegment(range: slot, adjustments: adjustmentsByClipID[clip.id] ?? .neutral)
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
            // Fades are durations, not edit points, so they stay in seconds at the sequence timescale.
            let fadeScale = sequenceRate.timescale
            for segment in audioSegments {
                let volume = Float(min(1, max(0, segment.adjustments.volume)))
                let maximumFade = max(0, segment.range.duration.seconds / 2)
                let fadeIn = min(maximumFade, max(0, segment.adjustments.fadeInSeconds))
                let fadeOut = min(maximumFade, max(0, segment.adjustments.fadeOutSeconds))
                let start = segment.range.start

                if fadeIn > 0 {
                    audioParameters.setVolumeRamp(
                        fromStartVolume: 0,
                        toEndVolume: volume,
                        timeRange: CMTimeRange(start: start, duration: CMTime(seconds: fadeIn, preferredTimescale: fadeScale))
                    )
                } else {
                    audioParameters.setVolume(volume, at: start)
                }

                if fadeOut > 0 {
                    let fadeDuration = CMTime(seconds: fadeOut, preferredTimescale: fadeScale)
                    let fadeStart = CMTimeSubtract(segment.range.end, fadeDuration)
                    audioParameters.setVolume(volume, at: fadeStart)
                    audioParameters.setVolumeRamp(
                        fromStartVolume: volume,
                        toEndVolume: 0,
                        timeRange: CMTimeRange(start: fadeStart, duration: fadeDuration)
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
                        let time = request.compositionTime
                        let adjustments = renderSegments.first(where: { $0.range.containsTime(time) })?.adjustments
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
                if let mutable = videoComposition.mutableCopy() as? AVMutableVideoComposition {
                    if let renderSize { mutable.renderSize = renderSize }
                    // Render exactly once per sequence frame.
                    mutable.frameDuration = sequenceRate.frameTime
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
