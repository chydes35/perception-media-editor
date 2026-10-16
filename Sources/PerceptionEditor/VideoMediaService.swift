import AppKit
@preconcurrency import AVFoundation

struct VideoMetadata: Sendable {
    var durationSeconds: Double
    var pixelWidth: Int?
    var pixelHeight: Int?
    var frameRate: FrameRate?
    var frameCount: Int64?
}

@MainActor
final class VideoMediaService {
    static let shared = VideoMediaService()

    private init() {}

    func metadata(for url: URL) async -> VideoMetadata {
        let asset = AVURLAsset(url: url)
        let durationTime = try? await asset.load(.duration)
        let duration = durationTime?.seconds ?? 0
        let videoTrack = (try? await asset.loadTracks(withMediaType: .video))?.first

        var transformedSize: CGSize?
        var frameRate: FrameRate?
        var frameCount: Int64?
        if let videoTrack {
            if let (minimum, range) = try? await videoTrack.load(.minFrameDuration, .timeRange),
               let rate = FrameRate(frameDuration: minimum) {
                frameRate = rate
                frameCount = rate.frame(containing: range.end, origin: range.start)
            }
            let naturalSize = try? await videoTrack.load(.naturalSize)
            let preferredTransform = try? await videoTrack.load(.preferredTransform)
            if let naturalSize, let preferredTransform {
                transformedSize = naturalSize.applying(preferredTransform)
            }
        }

        return VideoMetadata(
            durationSeconds: duration.isFinite && duration > 0 ? duration : 0,
            pixelWidth: transformedSize.map { Int(abs($0.width).rounded()) },
            pixelHeight: transformedSize.map { Int(abs($0.height).rounded()) },
            frameRate: frameRate,
            frameCount: frameCount
        )
    }

    func thumbnail(
        for url: URL,
        maximumSize: CGSize = CGSize(width: 640, height: 360)
    ) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumSize

        let requestedTime = CMTime(seconds: 0.1, preferredTimescale: 600)
        guard let result = try? await generator.image(at: requestedTime) else {
            return nil
        }
        let image = result.image
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

extension MediaAsset {
    mutating func apply(_ metadata: VideoMetadata) {
        durationSeconds = metadata.durationSeconds
        pixelWidth = metadata.pixelWidth
        pixelHeight = metadata.pixelHeight
        frameRate = metadata.frameRate
        frameCount = metadata.frameCount
    }
}

extension EditorProject {
    /// Fills in frame rates and counts read from the sources, then converts schema-10 clips of those
    /// sources from seconds to exact frames and re-packs the timeline. Clips whose source is still
    /// unknown (offline) keep their seconds. Returns whether any clip changed.
    @discardableResult
    mutating func adoptFrameMetadata(_ metadata: [UUID: VideoMetadata]) -> Bool {
        for index in media.indices {
            guard let found = metadata[media[index].id], found.frameRate != nil else { continue }
            media[index].frameRate = found.frameRate
            media[index].frameCount = found.frameCount
        }
        let rates = Dictionary(uniqueKeysWithValues: media.compactMap { asset in asset.frameRate.map { (asset.id, $0) } })
        var changed = false
        for index in timelineClips.indices where timelineClips[index].legacyTiming != nil {
            guard let rate = rates[timelineClips[index].assetID] else { continue }
            timelineClips[index].adoptFrameRate(rate)
            changed = true
        }
        if changed { packTimeline() }
        return changed
    }
}
