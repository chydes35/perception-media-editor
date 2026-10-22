@preconcurrency import AVFoundation
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PerceptionEditor

/// Gate G13 (plan Task 13.2) on the owner's iPhone 15 Pro clips: landscape, portrait, landscape on
/// one timeline through the compositor. Every frame must be at one render size, and the portrait
/// clip upright and pillarboxed; the middle frame of each clip is written as a PNG for the visual
/// check. Run with
///   PME_APPLELOG_SHORT=/Volumes/ExSSD1/PMVideoTestFiles/IMG_0001.MOV (landscape)
///   PME_APPLELOG_PORTRAIT=/Volumes/ExSSD1/PMVideoTestFiles/IMG_0004.MOV (portrait)
///   PME_APPLELOG_SKY=/Volumes/ExSSD1/PMVideoTestFiles/IMG_0002.MOV (landscape)
///   PME_VIDEO_OUTPUT_DIR=<a disposable folder>
@MainActor
struct RealVideoRotationTests {
    nonisolated static let environment = ProcessInfo.processInfo.environment
    nonisolated static let enabled = ["PME_APPLELOG_SHORT", "PME_APPLELOG_PORTRAIT", "PME_APPLELOG_SKY", "PME_VIDEO_OUTPUT_DIR"]
        .allSatisfy { environment[$0] != nil }

    @Test(.enabled(if: enabled))
    func landscapePortraitLandscapeStayUprightAtOneSize() async throws {
        let paths = ["PME_APPLELOG_SHORT", "PME_APPLELOG_PORTRAIT", "PME_APPLELOG_SKY"].map { Self.environment[$0]! }
        let output = URL(fileURLWithPath: Self.environment["PME_VIDEO_OUTPUT_DIR"]!)
        #expect(!output.path.contains("PMVideoTestFiles") && !output.path.contains("/Pictures/"), "Outputs never go next to the originals")
        var media: [MediaAsset] = []
        for path in paths {
            var asset = MediaAsset(url: URL(fileURLWithPath: path), kind: .video)
            asset.apply(await VideoMediaService.shared.metadata(for: asset.url))
            media.append(asset)
        }
        let rate = try #require(media[0].frameRate)
        let count: Int64 = 24
        var cursor: Int64 = 0
        let clips = media.map { asset -> TimelineClip in
            defer { cursor += count }
            return TimelineClip(assetID: asset.id, frameRate: rate, timelineStartFrame: cursor, sourceStartFrame: 48, durationFrames: count)
        }
        let result = await TimelineCompositionService.shared.makePlayerItem(clips: clips, media: media, quality: .preview, renderingPath: .compositor)
        let item = try #require(result.playerItem)
        let renderSize = try #require(item.videoComposition?.renderSize)
        print("G13: render size \(Int(renderSize.width))x\(Int(renderSize.height)); oriented sizes \(media.map { "\($0.pixelWidth ?? 0)x\($0.pixelHeight ?? 0)" })")
        #expect(renderSize == CGSize(width: 3840, height: 2160), "The first (landscape) clip sets the size")

        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.videoComposition = item.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 960, height: 540)
        var sizes: Set<String> = []
        for index in 0 ..< Int64(clips.count) * count {
            let image = try await generator.image(at: rate.time(ofFrame: index)).image
            sizes.insert("\(image.width)x\(image.height)")
            if index % count == count / 2 {
                let url = output.appendingPathComponent("g13-clip\(index / count + 1).png")
                let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(destination, image, nil)
                #expect(CGImageDestinationFinalize(destination))
                if index / count == 1 {
                    // The portrait clip fills 9/16 of the width; the pillars are black.
                    let (left, middle) = try Self.meanLuma(image, columns: [0.05, 0.5])
                    print("G13: portrait frame mean luma at the left edge \(left), in the middle \(middle)")
                    #expect(left < 2 && middle > 20, "Portrait clip should be pillarboxed (left \(left), middle \(middle))")
                }
            }
        }
        print("G13: \(clips.count * Int(count)) frames, sizes \(sizes)")
        #expect(sizes == ["960x540"], "No size change at the cuts: \(sizes)")
    }

    /// Mean 8-bit luma of a one-pixel-wide column at each fractional x position.
    private static func meanLuma(_ image: CGImage, columns: [Double]) throws -> (Double, Double) {
        let width = image.width, height = image.height
        var gray = [UInt8](repeating: 0, count: width * height)
        let context = try #require(CGContext(data: &gray, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let means = columns.map { fraction -> Double in
            let x = Int(Double(width) * fraction)
            return Double((0 ..< height).reduce(0) { $0 + Int(gray[$1 * width + x]) }) / Double(height)
        }
        return (means[0], means[1])
    }
}
