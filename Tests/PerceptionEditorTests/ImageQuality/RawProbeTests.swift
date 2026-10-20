import CoreImage
import Foundation
import Testing
@testable import PerceptionEditor

/// Opt-in probe on real RAW files: `PM_RAW_PROBE_DIR=<folder of RW2/DNG> swift test --filter RawProbe`.
/// Prints scene-linear statistics of the decode with and without the RAW engine's own tone curve.
struct RawProbeTests {
    private func stats(_ image: CIImage) -> (median: Double, p99: Double, over1: Double) {
        let side = 256
        let scale = CGFloat(side) / max(image.extent.width, image.extent.height)
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rect = small.extent.integral
        let width = Int(rect.width), height = Int(rect.height)
        var buffer = [Float](repeating: 0, count: width * height * 4)
        CIContext().render(small, toBitmap: &buffer, rowBytes: width * 16, bounds: rect, format: .RGBAf,
                           colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        var lumas: [Double] = []
        for index in stride(from: 0, to: buffer.count, by: 4) {
            lumas.append(0.2126 * Double(buffer[index]) + 0.7152 * Double(buffer[index + 1]) + 0.0722 * Double(buffer[index + 2]))
        }
        lumas.sort()
        let over = Double(lumas.filter { $0 > 1 }.count) / Double(lumas.count)
        return (lumas[lumas.count / 2], lumas[Int(Double(lumas.count) * 0.99)], over)
    }

    @Test func printDecodeStatistics() throws {
        guard let directory = ProcessInfo.processInfo.environment["PM_RAW_PROBE_DIR"] else { return }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory).filter { $0.uppercased().hasSuffix(".RW2") }.sorted()
        for name in files {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
            var display = RawSettings()
            display.sceneLinear = false
            var scene = RawSettings()
            scene.sceneLinear = true
            guard let legacy = PhotoSourceLoader.load(url, maxDimension: 1024, raw: display),
                  let linear = PhotoSourceLoader.load(url, maxDimension: 1024, raw: scene),
                  let filter = PhotoSourceLoader.makeRawFilter(url, settings: scene, maxDimension: 1024) else { continue }
            let a = stats(legacy), b = stats(linear)
            var v1 = PhotoAdjustments(); v1.processVersion = 1
            var v2 = PhotoAdjustments(); v2.processVersion = 2
            let out1 = IQRender.photo(legacy, v1, raw: true), out2 = IQRender.photo(linear, v2, raw: true)
            func outputStats(_ buffer: [UInt16]) -> (median: Double, clipped: Double, dark: Double) {
                var lumas: [Double] = []
                for i in stride(from: 0, to: buffer.count, by: 4) {
                    lumas.append(IQRender.luma((IQMetrics.srgbToLinear(Double(buffer[i]) / 65535),
                                                IQMetrics.srgbToLinear(Double(buffer[i + 1]) / 65535),
                                                IQMetrics.srgbToLinear(Double(buffer[i + 2]) / 65535))))
                }
                lumas.sort()
                return (lumas[lumas.count / 2], Double(lumas.filter { $0 > 0.97 }.count) / Double(lumas.count),
                        Double(lumas.filter { $0 < 0.01 }.count) / Double(lumas.count))
            }
            let d1 = outputStats(out1), d2 = outputStats(out2)
            print(String(format: "PROBE-OUT %@ v1 median %.3f clip %.1f%% black %.1f%% | v2 median %.3f clip %.1f%% black %.1f%%",
                         name, d1.median, d1.clipped * 100, d1.dark * 100, d2.median, d2.clipped * 100, d2.dark * 100))
            print(String(format: "PROBE %@ baselineExposure=%.2f boost=%.2f | legacy median %.3f p99 %.2f >1 %.1f%% | linear median %.4f p99 %.3f >1 %.1f%%",
                         name, filter.baselineExposure, filter.boostAmount, a.median, a.p99, a.over1 * 100, b.median, b.p99, b.over1 * 100))
        }
    }
}
