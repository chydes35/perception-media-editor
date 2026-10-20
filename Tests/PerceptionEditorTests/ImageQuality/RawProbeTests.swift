import CoreImage
import Foundation
import ImageIO
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
            for process in [1, 2] where ProcessInfo.processInfo.environment["PM_RAW_PROBE_SKIP_AUTO"] == nil {
                var current = PhotoAdjustments(); current.processVersion = process
                guard let suggestion = try? AutoAdjustmentAnalyzer().analyze(url: url, current: current) else { continue }
                let applied = suggestion.applying(to: current)
                guard let source = PhotoSourceLoader.load(url, maxDimension: 1024, raw: applied.decodeSettings) else { continue }
                let before = outputStats(IQRender.photo(process == 1 ? legacy : linear, current, raw: true))
                let after = outputStats(IQRender.photo(source, applied, raw: true))
                print(String(format: "PROBE-AUTO %@ P%d exp %+.2f con %+.2f hi %+.2f sh %+.2f | median %.3f → %.3f clip %.1f%% → %.1f%%",
                             name, process, applied.exposure, applied.contrast, applied.highlights, applied.shadows,
                             before.median, after.median, before.clipped * 100, after.clipped * 100))
            }
            print(String(format: "PROBE %@ baselineExposure=%.2f boost=%.2f | legacy median %.3f p99 %.2f >1 %.1f%% | linear median %.4f p99 %.3f >1 %.1f%%",
                         name, filter.baselineExposure, filter.boostAmount, a.median, a.p99, a.over1 * 100, b.median, b.p99, b.over1 * 100))
        }
    }

    private func peakMegabytes() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_maxrss) / 1_048_576
    }

    /// `PM_EXPORT_PROBE=1 PM_RAW_PROBE_DIR=<folder>`: exports one real RAW at full resolution in every
    /// format, with process 2, and prints size, depth, metadata and the process's peak memory.
    @Test func exportEveryFormat() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PM_EXPORT_PROBE"] != nil, let directory = environment["PM_RAW_PROBE_DIR"] else { return }
        let name = try FileManager.default.contentsOfDirectory(atPath: directory)
            .filter { $0.uppercased().hasSuffix(".RW2") }.sorted().first
        let source = URL(fileURLWithPath: directory).appendingPathComponent(try #require(name))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("export-probe-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var adjustments = PhotoAdjustments()
        adjustments.processVersion = 2
        print(String(format: "EXPORT-PROBE start peak %.0f MB", peakMegabytes()))
        for format in ExportFormat.allCases {
            var recipe = BatchExportRecipe(format: format, sharpening: format == .jpeg ? .standard : .none)
            recipe.metadata.copyright = "© 2026 Perception Media"
            let output = folder.appendingPathComponent("probe.\(format.fileExtension)")
            let started = Date()
            try await PhotoRenderer(workingCacheLimit: 0, memoryTargetMB: 128)
                .export(url: source, adjustments: adjustments, to: output, recipe: recipe)
            let seconds = Date().timeIntervalSince(started)
            let properties = ExportMetadata.sourceProperties(of: output)
            let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
            let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
            print(String(format: "EXPORT-PROBE %@ %dx%d depth %@ %.1f MB file, %.1f s, peak %.0f MB, gps %@ serial %@ exposure %@",
                         format.rawValue,
                         properties[kCGImagePropertyPixelWidth as String] as? Int ?? 0,
                         properties[kCGImagePropertyPixelHeight as String] as? Int ?? 0,
                         "\(properties[kCGImagePropertyDepth as String] ?? "?")", Double(size) / 1_048_576, seconds, peakMegabytes(),
                         properties[kCGImagePropertyGPSDictionary as String] == nil ? "removed" : "present",
                         exif[kCGImagePropertyExifBodySerialNumber as String] == nil ? "removed" : "present",
                         exif[kCGImagePropertyExifExposureTime as String] == nil ? "MISSING" : "kept"))
        }
    }
}
