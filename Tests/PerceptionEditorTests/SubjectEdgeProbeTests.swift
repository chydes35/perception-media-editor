import CoreImage
import Foundation
import Testing
@testable import PerceptionEditor

/// Opt-in diagnostic: writes each photo, its subject union mask, and guided-filter variants as overlays.
struct SubjectEdgeProbeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PME_EDGE_PROBE_INPUTS"] != nil))
    func writeEdgeOverlays() throws {
        let env = ProcessInfo.processInfo.environment
        let inputs = try #require(env["PME_EDGE_PROBE_INPUTS"]).split(separator: ",").map { URL(fileURLWithPath: String($0)) }
        let output = URL(fileURLWithPath: try #require(env["PME_EDGE_PROBE_OUTPUT"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let context = CIContext(options: [.cacheIntermediates: false])
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        for url in inputs {
            let name = url.deletingPathExtension().lastPathComponent
            let analysis: SubjectAnalysis
            do { analysis = try SubjectAnalyzer.analyze(url: url) } catch { print("EDGE_PROBE", name, "error", error); continue }
            let source = try #require(PhotoSourceLoader.load(url, maxDimension: 1536))
            let w = Int(source.extent.width), h = Int(source.extent.height)
            var rgba = [UInt8](repeating: 0, count: w * h * 4)
            context.render(source, toBitmap: &rgba, rowBytes: w * 4, bounds: source.extent, format: .RGBA8, colorSpace: srgb)
            var guide = [Float](repeating: 0, count: w * h)
            for i in 0 ..< w * h {
                let r = Float(rgba[i * 4]), g = Float(rgba[i * 4 + 1]), b = Float(rgba[i * 4 + 2])
                guide[i] = (0.299 * r + 0.587 * g + 0.114 * b) / 255
            }
            let maskImage = try #require(CIImage(data: analysis.allSubjectsPNG, options: [.colorSpace: NSNull()]))
            let scaled = maskImage.transformed(by: CGAffineTransform(scaleX: source.extent.width / maskImage.extent.width,
                                                                     y: source.extent.height / maskImage.extent.height))
            var maskBytes = [UInt8](repeating: 0, count: w * h * 4)
            context.render(scaled, toBitmap: &maskBytes, rowBytes: w * 4, bounds: source.extent, format: .RGBA8, colorSpace: nil)
            var mask = [Float](repeating: 0, count: w * h)
            for i in 0 ..< w * h { mask[i] = Float(maskBytes[i * 4]) / 255 }
            var rgb = [Float](repeating: 0, count: w * h * 3)
            for i in 0 ..< w * h {
                for c in 0 ..< 3 { rgb[i * 3 + c] = Float(rgba[i * 4 + c]) / 255 }
            }
            let started = Date()
            let matte = SubjectEdgeMatting.refine(mask: mask, rgb: rgb, width: w, height: h)
            print("EDGE_PROBE matte seconds", name, Date().timeIntervalSince(started), "px", w * h)
            let variants: [(String, [Float])] = [
                ("matte", matte),
                ("base", mask),
                ("r8e3", SkyEdgeRefiner.refine(mask: mask, guide: guide, width: w, height: h, radius: 8, epsilon: 1e-3)),
                ("r16e3", SkyEdgeRefiner.refine(mask: mask, guide: guide, width: w, height: h, radius: 16, epsilon: 1e-3)),
            ]
            try write(rgba, w, h, to: output.appendingPathComponent("\(name)-source.jpg"))
            for (label, values) in variants {
                var out = rgba
                for i in 0 ..< w * h {
                    let a = values[i] * 0.55
                    out[i * 4] = UInt8(Float(out[i * 4]) * (1 - a) + 255 * a)
                    out[i * 4 + 1] = UInt8(Float(out[i * 4 + 1]) * (1 - a))
                    out[i * 4 + 2] = UInt8(Float(out[i * 4 + 2]) * (1 - a))
                }
                try write(out, w, h, to: output.appendingPathComponent("\(name)-\(label).jpg"))
            }
            print("EDGE_PROBE", name, analysis.candidates.map(\.name))
        }
    }

    private func write(_ rgba: [UInt8], _ w: Int, _ h: Int, to url: URL) throws {
        let data = Data(rgba)
        let image = CIImage(bitmapData: data, bytesPerRow: w * 4, size: CGSize(width: w, height: h), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        try CIContext().writeJPEGRepresentation(of: image, to: url, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [:])
    }
}
