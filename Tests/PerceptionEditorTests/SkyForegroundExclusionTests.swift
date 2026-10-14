import CoreImage
import Foundation
import Testing
@testable import PerceptionEditor

struct SkyForegroundExclusionTests {
    @Test func onlyPersonDominatedInstancesQualifyForExclusion() throws {
        let labels = [UInt8](repeating: 1, count: 20) + [UInt8](repeating: 2, count: 20) + [3, 3]
        let people = [UInt8](repeating: 255, count: 12) + [UInt8](repeating: 0, count: 8)
            + [UInt8](repeating: 0, count: 20) + [255, 255]
        #expect(try SkyForegroundExclusion.personInstances(labels: labels, semanticPeople: people) == IndexSet(integer: 1))
    }

    @Test func uncertainEdgesAndUnrelatedSkyRemainUnchanged() throws {
        let sky: [Float] = [1, 1, 1, 0, 0.5]
        let result = try SkyForegroundExclusion.exclude(sky: sky, foreground: [0, 230, 255, 255, 240])
        #expect(result == [1, 1, 0, 0, 0.3])
        #expect(try SkyForegroundExclusion.exclude(sky: sky, foreground: []) == sky)
    }

    @Test func auxiliaryFailureRetainsUsableSky() throws {
        let context = CIContext(options: [.cacheIntermediates: false])
        defer { context.clearCaches() }
        let sky: [Float] = [0.2, 0.8]
        #expect(try SkyForegroundExclusion.refine(sky: sky, source: CIImage.empty(), semanticPeople: CIImage.empty(),
                                                 width: 2, height: 1, context: context) == sky)
    }

    @Test func cancellationPreventsForegroundPublication() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try SkyForegroundExclusion.exclude(sky: [1], foreground: [255])
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PME_SKY_FOREGROUND_INPUT"] != nil))
    func brightBowIsExcludedFromSavedSkyRaster() throws {
        let env = ProcessInfo.processInfo.environment
        let path = try #require(env["PME_SKY_FOREGROUND_INPUT"])
        let modelPath = try #require(env["PERCEPTION_SKY_MODEL_PATH"])
        let model = try SkyAnalyzer.loadModel(at: URL(fileURLWithPath: modelPath))
        let url = URL(fileURLWithPath: path)
        let png = try SkyAnalyzer.analyze(url: url, model: model)
        let image = try #require(CIImage(data: png, options: [.colorSpace: NSNull()]))
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])
        defer { context.clearCaches() }
        let width = Int(image.extent.width), height = Int(image.extent.height)
        var pixels = [UInt8](repeating: 0, count: width * height)
        context.render(image, toBitmap: &pixels, rowBytes: width, bounds: image.extent, format: .L8, colorSpace: nil)
        for (x, y) in [(0.46, 0.15), (0.54, 0.12), (0.46, 0.47)] {
            let weight = pixels[Int(y * Double(height)) * width + Int(x * Double(width))]
            print("SKY_FOREGROUND sample", x, y, weight)
            #expect(weight < 50)
        }
        let raster = SubjectMask(png: png)
        let mask = LocalMask(shape: .sky(raster))
        #expect(try JSONDecoder().decode(LocalMask.self, from: JSONEncoder().encode(mask)) == mask)
        if let folderPath = env["PME_SKY_FOREGROUND_OUTPUT"] {
            let folder = URL(fileURLWithPath: folderPath)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: folder.appendingPathComponent("corrected-sky.png"), options: .atomic)
            var project = EditorProject.starter
            let dimensions = try #require(PhotoSourceLoader.dimensions(of: url))
            project.media = [MediaAsset(url: url, pixelWidth: dimensions.width, pixelHeight: dimensions.height)]
            try ProjectDocument().data(for: project).write(to: folder.appendingPathComponent("ForegroundQA.pmedit"), options: .atomic)
        }
    }

}
