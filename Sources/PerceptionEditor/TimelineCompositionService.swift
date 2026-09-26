@preconcurrency import AVFoundation
import CoreImage
import Foundation

struct TimelineCompositionResult {
    var playerItem: AVPlayerItem?
    var durationSeconds: Double
    var insertedClipIDs: [UUID]
    var warnings: [String]
}

private struct TimelineColorSegment: Sendable {
    var startSeconds: Double
    var durationSeconds: Double
    var adjustments: PhotoAdjustments

    func contains(_ seconds: Double) -> Bool {
        seconds >= startSeconds && seconds < startSeconds + durationSeconds
    }
}

private struct SendableVideoComposition: @unchecked Sendable {
    let value: AVVideoComposition?
}

@MainActor
final class TimelineCompositionService {
    static let shared = TimelineCompositionService()

    private init() {}

    func makePlayerItem(
        clips: [TimelineClip],
        media: [MediaAsset],
        adjustmentsByClipID: [UUID: PhotoAdjustments] = [:]
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
                warnings: ["The video composition track could not be created."]
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
        var warnings: [String] = []
        var didSetVideoTransform = false

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

            let sourceAsset = AVURLAsset(url: mediaAsset.url)
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

            if !didSetVideoTransform,
               let preferredTransform = try? await sourceVideoTrack.load(.preferredTransform) {
                compositionVideoTrack.preferredTransform = preferredTransform
                didSetVideoTransform = true
            }

            if !clip.isMuted,
               let compositionAudioTrack,
               let sourceAudioTrack = (try? await sourceAsset.loadTracks(withMediaType: .audio))?.first {
                do {
                    try compositionAudioTrack.insertTimeRange(
                        sourceRange,
                        of: sourceAudioTrack,
                        at: insertionTime
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
                warnings: warnings.isEmpty ? ["The timeline has no playable clips."] : warnings
            )
        }

        let durationSeconds = composition.duration.seconds
        let playerItem = AVPlayerItem(asset: composition)
        if colorSegments.contains(where: { $0.adjustments != .neutral }) {
            let renderSegments = colorSegments
            let videoCompositionResult: SendableVideoComposition = await withCheckedContinuation { continuation in
                AVVideoComposition.videoComposition(
                    with: composition,
                    applyingCIFiltersWithHandler: { request in
                        let seconds = request.compositionTime.seconds
                        let adjustments = renderSegments.first(where: { $0.contains(seconds) })?.adjustments
                            ?? .neutral
                        let output = MediaColorRenderer.render(
                            request.sourceImage,
                            adjustments: adjustments,
                            includesGeometry: false
                        )
                        request.finish(with: output.cropped(to: request.sourceImage.extent), context: nil)
                    },
                    completionHandler: { videoComposition, _ in
                        continuation.resume(returning: SendableVideoComposition(value: videoComposition))
                    }
                )
            }
            if let videoComposition = videoCompositionResult.value {
                playerItem.videoComposition = videoComposition
            } else {
                warnings.append("Clip color could not be previewed.")
            }
        }

        return TimelineCompositionResult(
            playerItem: playerItem,
            durationSeconds: durationSeconds.isFinite ? max(0, durationSeconds) : 0,
            insertedClipIDs: insertedClipIDs,
            warnings: warnings
        )
    }
}
