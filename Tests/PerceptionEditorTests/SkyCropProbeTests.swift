import CoreImage
import Foundation
import Testing
@testable import PerceptionEditor

/// Opt-in bounded experiment. Artifacts require photographic inspection.
struct SkyCropProbeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PME_SKY_CROP_PROBE_INPUT"] != nil))
    func inspectOverlappingSkyCrops() throws {
        let env = ProcessInfo.processInfo.environment
        let input = URL(fileURLWithPath: try #require(env["PME_SKY_CROP_PROBE_INPUT"]))
        let output = URL(fileURLWithPath: try #require(env["PME_SKY_CROP_PROBE_OUTPUT"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let model = try SkyAnalyzer.loadModel(at: URL(fileURLWithPath: try #require(env["PERCEPTION_SKY_MODEL_PATH"])))
        let source = try #require(PhotoSourceLoader.load(input, maxDimension: SkyAnalyzer.maximumMaskDimension))
        let context = CIContext(options: [.cacheIntermediates: false])
        defer { context.clearCaches() }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        var union = CIImage(color: .black).cropped(to: source.extent)
        for (index, origin) in [(0.0, 0.0), (0.4, 0.0), (0.0, 0.4), (0.4, 0.4)].enumerated() {
            let rect = CGRect(x: origin.0 * source.extent.width, y: origin.1 * source.extent.height,
                              width: 0.6 * source.extent.width, height: 0.6 * source.extent.height)
                .integral.intersection(source.extent)
            let crop = source.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            let url = output.appendingPathComponent("crop-\(index).png")
            try context.writePNGRepresentation(of: crop, to: url, format: .RGBA8, colorSpace: colorSpace)
            let start = Date()
            do {
                let png = try SkyAnalyzer.analyze(url: url, model: model)
                try png.write(to: output.appendingPathComponent("mask-\(index).png"))
                let mask = try #require(CIImage(data: png, options: [.colorSpace: NSNull()]))
                let positioned = mask.transformed(by: CGAffineTransform(scaleX: rect.width / mask.extent.width,
                                                                        y: rect.height / mask.extent.height))
                    .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
                    .composited(over: CIImage(color: .black).cropped(to: source.extent))
                let merged = union.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: positioned])
                union = try #require(CIImage(data: SubjectAnalyzer.encodeMask(merged), options: [.colorSpace: NSNull()]))
                print("SKY_CROP_PROBE", index, "seconds", Date().timeIntervalSince(start), "mask generated")
            } catch SkySelectionError.noSky {
                print("SKY_CROP_PROBE", index, "seconds", Date().timeIntervalSince(start), "no sky")
            }
        }
        try SubjectAnalyzer.encodeMask(union).write(to: output.appendingPathComponent("union.png"))
    }
}
