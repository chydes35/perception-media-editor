import AppKit
import AVFoundation

struct VideoMetadata: Sendable {
    var durationSeconds: Double
    var pixelWidth: Int?
    var pixelHeight: Int?
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
        if let videoTrack {
            let naturalSize = try? await videoTrack.load(.naturalSize)
            let preferredTransform = try? await videoTrack.load(.preferredTransform)
            if let naturalSize, let preferredTransform {
                transformedSize = naturalSize.applying(preferredTransform)
            }
        }

        return VideoMetadata(
            durationSeconds: duration.isFinite && duration > 0 ? duration : 0,
            pixelWidth: transformedSize.map { Int(abs($0.width).rounded()) },
            pixelHeight: transformedSize.map { Int(abs($0.height).rounded()) }
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
