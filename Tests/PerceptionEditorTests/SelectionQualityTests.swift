import CoreImage
import Foundation
import Testing
@testable import PerceptionEditor

/// Local diagnostic artifacts, not an automatic segmentation-quality verdict.
@Suite(.serialized)
struct SelectionQualityTests {
    private struct Fixture: Decodable {
        let name: String
        let path: String
        let kind: String
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PME_SELECTION_MANIFEST"] != nil))
    func realRawSelectionArtifactsPreserveMasksThroughExport() async throws {
        let env = ProcessInfo.processInfo.environment
        let manifest = URL(fileURLWithPath: try #require(env["PME_SELECTION_MANIFEST"]))
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: manifest))
        let output = URL(fileURLWithPath: try #require(env["PME_SELECTION_OUTPUT_DIR"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let model = try SkyAnalyzer.loadModel(at: URL(fileURLWithPath: try #require(env["PERCEPTION_SKY_MODEL_PATH"])))
        var observations: [[String: String]] = []
        for (index, fixture) in fixtures.enumerated() {
            let source = URL(fileURLWithPath: fixture.path)
            let folder = output.appendingPathComponent(String(format: "%02d", index + 1))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let renderer = PhotoRenderer(workingCacheLimit: 0, memoryTargetMB: 128)
            let before = try #require(await renderer.preview(url: source, adjustments: .neutral))
            try write(before.edited.cgImage, to: folder.appendingPathComponent("before.png"))
            var record = ["name": fixture.name, "kind": fixture.kind, "folder": folder.lastPathComponent]
            let start = Date()
            let png: Data
            do {
                switch fixture.kind {
                case "sky": png = try SkyAnalyzer.analyze(url: source, model: model)
                case "subject":
                    let analysis = try SubjectAnalyzer.analyze(url: source)
                    record["candidates"] = analysis.candidates.map { $0.name }.joined(separator: ", ")
                    for candidate in analysis.candidates {
                        try candidate.png.write(to: folder.appendingPathComponent("candidate-\(candidate.id).png"), options: .atomic)
                    }
                    png = analysis.allSubjectsPNG
                default: throw NSError(domain: "InvalidSelectionFixtureKind", code: 1)
                }
            } catch let error as SkySelectionError where error == .noSky {
                record["outcome"] = "no sky detected"
                record["analysisSeconds"] = String(Date().timeIntervalSince(start))
                observations.append(record)
                await renderer.evictAll()
                continue
            } catch SubjectSelectionError.noSubjects {
                record["outcome"] = "no foreground subjects detected"
                record["analysisSeconds"] = String(Date().timeIntervalSince(start))
                observations.append(record)
                await renderer.evictAll()
                continue
            }
            record["analysisSeconds"] = String(Date().timeIntervalSince(start))
            try png.write(to: folder.appendingPathComponent("mask.png"), options: .atomic)
            let raster = SubjectMask(png: png)
            var mask = LocalMask(shape: fixture.kind == "sky" ? .sky(raster) : .subject(raster))
            mask.adjustments.exposure = -1
            var edits = PhotoAdjustments()
            edits.masks = [mask]
            let roundTrip = try JSONDecoder().decode(PhotoAdjustments.self, from: JSONEncoder().encode(edits))
            #expect(roundTrip == edits)
            let preview = try #require(await renderer.preview(url: source, adjustments: roundTrip, overlayMaskID: mask.id))
            let overlay = try #require(preview.maskOverlay)
            #expect(overlay.cgImage.width == preview.edited.cgImage.width)
            #expect(overlay.cgImage.height == preview.edited.cgImage.height)
            try write(preview.edited.cgImage, to: folder.appendingPathComponent("edited-preview.png"))
            let base = CIImage(cgImage: before.edited.cgImage)
            let tinted = CIImage(cgImage: overlay.cgImage).composited(over: base)
            let comparison = base.applyingFilter("CIDissolveTransition", parameters: [
                "inputTargetImage": tinted, "inputTime": 0.35
            ])
            let context = CIContext(options: [.cacheIntermediates: false])
            let composite = try #require(context.createCGImage(comparison, from: base.extent))
            try write(composite, to: folder.appendingPathComponent("overlay.png"))
            let exported = folder.appendingPathComponent("edited-export.png")
            try await renderer.export(url: source, adjustments: roundTrip, to: exported, type: .png, longEdgePixels: 2048)
            let dimensions = try #require(PhotoSourceLoader.dimensions(of: exported))
            #expect(max(dimensions.width, dimensions.height) == 2048)
            record["outcome"] = "artifacts generated; visual quality requires inspection"
            observations.append(record)
            await renderer.evictAll()
        }
        try JSONSerialization.data(withJSONObject: observations, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("observations.json"), options: .atomic)
        print("SELECTION QA generated observations for \(observations.count) fixtures; no automatic quality verdict")
    }

    private func write(_ image: CGImage, to url: URL) throws {
        try CIContext(options: [.cacheIntermediates: false]).writePNGRepresentation(
            of: CIImage(cgImage: image), to: url, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }
}
