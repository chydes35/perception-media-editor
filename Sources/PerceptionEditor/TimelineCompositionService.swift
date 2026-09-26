import AVFoundation
import Foundation

struct TimelineCompositionResult {
    var playerItem: AVPlayerItem?
    var durationSeconds: Double
    var insertedClipIDs: [UUID]
    var warnings: [String]
}

@MainActor
final class TimelineCompositionService {
    static let shared = TimelineCompositionService()

    private init() {}

    func makePlayerItem(
        clips: [TimelineClip],
        media: [MediaAsset]
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
        return TimelineCompositionResult(
            playerItem: AVPlayerItem(asset: composition),
            durationSeconds: durationSeconds.isFinite ? max(0, durationSeconds) : 0,
            insertedClipIDs: insertedClipIDs,
            warnings: warnings
        )
    }
}
