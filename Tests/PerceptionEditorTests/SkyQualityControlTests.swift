import CoreImage
import Foundation
import Testing
@testable import PerceptionEditor

/// Annotated local RAW controls. Passing sampled points does not establish whole-mask quality.
struct SkyQualityControlTests {
    private struct Fixture: Decodable {
        let name: String
        let path: String
        let expectNoSky: Bool
        let points: [Point]
        let baselineMaskPath: String?
    }

    private struct Point: Decodable {
        let name: String
        /// Normalized coordinates in the oriented photo, measured from its top-left corner.
        let x: Double
        let y: Double
        let minimum: Int
        let maximum: Int
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PME_SKY_CONTROL_MANIFEST"] != nil))
    func annotatedBlueObjectsAndVariedSkyRemainSeparated() throws {
        let env = ProcessInfo.processInfo.environment
        let manifest = URL(fileURLWithPath: try #require(env["PME_SKY_CONTROL_MANIFEST"]))
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: manifest))
        #expect(!fixtures.isEmpty)
        let output = URL(fileURLWithPath: try #require(env["PME_SKY_CONTROL_OUTPUT_DIR"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let model = try SkyAnalyzer.loadModel(at: URL(fileURLWithPath: try #require(env["PERCEPTION_SKY_MODEL_PATH"])))
        var observations: [[String: Any]] = []
        for (index, fixture) in fixtures.enumerated() {
            try Task.checkCancellation()
            let start = Date()
            let png: Data
            do {
                png = try SkyAnalyzer.analyze(url: URL(fileURLWithPath: fixture.path), model: model)
            } catch SkySelectionError.noSky {
                #expect(fixture.expectNoSky, "Unexpected empty sky: \(fixture.name)")
                observations.append(["name": fixture.name, "outcome": "no sky", "analysisSeconds": Date().timeIntervalSince(start)])
                continue
            }
            #expect(!fixture.expectNoSky, "Unexpected sky: \(fixture.name)")
            let image = try #require(CIImage(data: png, options: [.colorSpace: NSNull()]))
            let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])
            defer { context.clearCaches() }
            let width = Int(image.extent.width), height = Int(image.extent.height)
            var pixels = [UInt8](repeating: 0, count: width * height)
            context.render(image, toBitmap: &pixels, rowBytes: width, bounds: image.extent, format: .L8, colorSpace: nil)
            var samples: [[String: Any]] = []
            for point in fixture.points {
                try #require(point.x >= 0 && point.x < 1 && point.y >= 0 && point.y < 1)
                try #require(point.minimum >= 0 && point.minimum <= point.maximum && point.maximum <= 255)
                // Core Image bitmap rows follow the mask's top-first representation.
                let value = Int(pixels[Int(point.y * Double(height)) * width + Int(point.x * Double(width))])
                #expect(value >= point.minimum && value <= point.maximum, "\(fixture.name): \(point.name) = \(value)")
                samples.append(["name": point.name, "x": point.x, "y": point.y, "weight": value,
                                "minimum": point.minimum, "maximum": point.maximum])
            }
            var record: [String: Any] = ["name": fixture.name, "outcome": "annotated points checked", "points": samples,
                                         "analysisSeconds": Date().timeIntervalSince(start)]
            if let path = fixture.baselineMaskPath {
                let baseline = try #require(CIImage(contentsOf: URL(fileURLWithPath: path), options: [.colorSpace: NSNull()]))
                try #require(baseline.extent == image.extent)
                var previous = [UInt8](repeating: 0, count: pixels.count)
                context.render(baseline, toBitmap: &previous, rowBytes: width, bounds: baseline.extent, format: .L8, colorSpace: nil)
                // A different complete analyzer configuration is not this prediction's baseline.
                // Record both directions without assuming identical inference/rendering.
                record["increasedPixels"] = zip(previous, pixels).filter { Int($1) > Int($0) + 1 }.count
                record["decreasedPixels"] = zip(previous, pixels).filter { Int($1) + 1 < Int($0) }.count
            }
            try png.write(to: output.appendingPathComponent(String(format: "%02d-mask.png", index + 1)), options: .atomic)
            observations.append(record)
        }
        try JSONSerialization.data(withJSONObject: observations, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("observations.json"), options: .atomic)
        print("SKY CONTROLS checked \(fixtures.count) RAWs; whole-mask photographic quality remains a separate gate")
    }
}
