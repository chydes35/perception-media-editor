import CoreImage
import Foundation
import Testing
@testable import PerceptionEditor

struct SkyBranchRecoveryTests {
    @Test func recoveryRequiresSkyEvidenceAndExcludesObjectsWoodAndLowerBlueRegions() throws {
        let width = 80, height = 40
        var mask = [UInt8](repeating: 0, count: width * height)
        var trees = [UInt8](repeating: 255, count: mask.count)
        var rgba = [UInt8](repeating: 255, count: mask.count * 4)
        for i in mask.indices {
            rgba[i * 4] = 70; rgba[i * 4 + 1] = 130; rgba[i * 4 + 2] = 200
        }
        #expect(try SkyBranchRecovery.recover(mask: mask, rgba: rgba, trees: trees, width: width, height: height) == mask)
        for y in 0..<4 {
            for x in 40..<width { mask[y * width + x] = 255 }
        }
        let gap = 2 * width + 25, object = 2 * width + 10, wood = 2 * width + 26, lowerBlue = 30 * width + 25
        trees[object] = 0
        rgba[wood * 4] = 130; rgba[wood * 4 + 1] = 105; rgba[wood * 4 + 2] = 80
        let recovered = try SkyBranchRecovery.recover(mask: mask, rgba: rgba, trees: trees, width: width, height: height)
        #expect(recovered[gap] == 255)
        #expect(recovered[object] == 0 && recovered[wood] == 0 && recovered[lowerBlue] == 0)
        #expect(zip(mask, recovered).allSatisfy { $0 <= $1 })
    }

    @Test func canceledRecoveryStopsBeforePublishingPixels() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try SkyBranchRecovery.recover(mask: [0], rgba: [0, 0, 255, 255], trees: [255], width: 1, height: 1)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PME_SKY_NEGATIVE_MANIFEST"] != nil))
    func realIndoorAndBlueFabricPhotosRemainRejected() throws {
        let env = ProcessInfo.processInfo.environment
        let path = try #require(env["PME_SKY_NEGATIVE_MANIFEST"])
        let paths = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(paths.count >= 3)
        let model = try SkyAnalyzer.loadModel(at: URL(fileURLWithPath: try #require(env["PERCEPTION_SKY_MODEL_PATH"])))
        for path in paths {
            #expect(throws: SkySelectionError.noSky) {
                try SkyAnalyzer.analyze(url: URL(fileURLWithPath: path), model: model)
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PME_SKY_BRANCH_INPUT"] != nil))
    func branchGapsImproveWithoutSelectingAnnotatedWood() throws {
        let env = ProcessInfo.processInfo.environment
        let path = try #require(env["PME_SKY_BRANCH_INPUT"])
        let model = try SkyAnalyzer.loadModel(at: URL(fileURLWithPath: try #require(env["PERCEPTION_SKY_MODEL_PATH"])))
        let png = try SkyAnalyzer.analyze(url: URL(fileURLWithPath: path), model: model)
        let image = try #require(CIImage(data: png, options: [.colorSpace: NSNull()]))
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        func weight(_ x: Double, _ y: Double) -> UInt8 {
            var pixel: UInt8 = 0
            context.render(image, toBitmap: &pixel, rowBytes: 1,
                           bounds: CGRect(x: x * image.extent.width, y: (1 - y) * image.extent.height, width: 1, height: 1),
                           format: .L8, colorSpace: nil)
            return pixel
        }
        for (x, y) in [(0.62, 0.04), (0.44, 0.12), (0.48, 0.16), (0.52, 0.10)] {
            print("SKY_GAP weight", x, y, weight(x, y))
            #expect(weight(x, y) > 150)
        }
        print("SKY_UNRESOLVED shaded gap", weight(0.32, 0.035))
        for (x, y) in [(0.063, 0.45), (0.11, 0.13), (0.23, 0.17), (0.5, 0.8)] {
            print("SKY_NEGATIVE weight", x, y, weight(x, y))
            #expect(weight(x, y) < 50)
        }
        if let baselinePath = env["PME_SKY_BASELINE_MASK"] {
            let baseline = try #require(CIImage(contentsOf: URL(fileURLWithPath: baselinePath), options: [.colorSpace: NSNull()]))
            #expect(baseline.extent == image.extent)
            let width = Int(image.extent.width), height = Int(image.extent.height)
            var before = [UInt8](repeating: 0, count: width * height)
            var after = before
            context.render(baseline, toBitmap: &before, rowBytes: width, bounds: image.extent, format: .L8, colorSpace: nil)
            context.render(image, toBitmap: &after, rowBytes: width, bounds: image.extent, format: .L8, colorSpace: nil)
            #expect(zip(before, after).allSatisfy { Int($1) + 1 >= Int($0) })
        }
        if let outputPath = env["PME_SKY_QA_PROJECT_OUTPUT"] {
            var project = EditorProject.starter
            let url = URL(fileURLWithPath: path)
            let dimensions = try #require(PhotoSourceLoader.dimensions(of: url))
            project.media = [MediaAsset(url: url, pixelWidth: dimensions.width, pixelHeight: dimensions.height)]
            try ProjectDocument().data(for: project).write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        }
    }
}
