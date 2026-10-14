import Foundation
import ImageIO
import Testing
@testable import PerceptionEditor

/// Opt-in reproduction using a disposable saved RAW project from target-Mac QA.
/// Run alone after closing the app so renderer timings and memory stay separate.
@Suite(.serialized)
struct RealWorkflowTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PME_WORKFLOW_PROJECT"] != nil))
    func savedRawPortraitHasANativeSubjectCandidate() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["PME_WORKFLOW_PROJECT"])
        let project = try ProjectDocument().load(from: URL(fileURLWithPath: path))
        let asset = try #require(project.media.first { !(project.adjustmentsByAssetID[$0.id]?.retouches.isEmpty ?? true) })
        let analysis = try await SubjectAnalysisService().analyze(url: asset.url)
        #expect(!analysis.candidates.isEmpty)
        print("WORKFLOW_SUBJECT native candidates=\(analysis.candidates.count)")
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    private func image(_ url: URL) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PME_WORKFLOW_PROJECT"] != nil))
    func savedRawRepairsAndMasksExportTogether() async throws {
        let env = ProcessInfo.processInfo.environment
        let projectURL = URL(fileURLWithPath: try #require(env["PME_WORKFLOW_PROJECT"]))
        let project = try ProjectDocument().load(from: projectURL)
        let asset = try #require(project.media.first { asset in
            guard let edits = project.adjustmentsByAssetID[asset.id] else { return false }
            return !edits.masks.isEmpty && !edits.retouches.isEmpty
        })
        let edited = try #require(project.adjustmentsByAssetID[asset.id])
        let output = URL(fileURLWithPath: try #require(env["PME_WORKFLOW_OUTPUT_DIR"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var global = edited
        global.masks = []; global.retouches = []
        var masks = edited; masks.retouches = []
        var heal = edited; heal.masks = []
        for budget in [Optional(128), nil] {
            for (name, edits) in [("global", global), ("masks", masks), ("heal", heal), ("combined", edited)] {
                let renderer = PhotoRenderer(workingCacheLimit: 0, memoryTargetMB: budget)
                let file = output.appendingPathComponent("\(name)-\(budget.map(String.init) ?? "unbounded").jpg")
                do {
                    try await renderer.export(url: asset.url, adjustments: edits, to: file, type: .jpeg,
                                              protectedOriginals: project.media.map(\.url), longEdgePixels: 2048)
                    let size = try #require(PhotoSourceLoader.dimensions(of: file))
                    #expect(max(size.width, size.height) == 2048)
                    print("WORKFLOW_EXPORT \(name) budget=\(String(describing: budget)) PASS")
                } catch {
                    let failure = error as NSError
                    print("WORKFLOW_EXPORT \(name) budget=\(String(describing: budget)) FAIL \(failure.domain)/\(failure.code) \(failure.userInfo)")
                    #expect(Bool(false), "\(name) export failed: \(failure)")
                }
            }
        }
        for name in ["heal", "combined"] {
            let actual = try pixels(image(output.appendingPathComponent("\(name)-128.jpg")))
            let reference = try pixels(image(output.appendingPathComponent("\(name)-unbounded.jpg")))
            #expect(actual.count == reference.count)
            let difference = zip(actual, reference).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
            #expect(difference <= 1, "Bounded \(name) export changed channels by \(difference)/255")
            print("WORKFLOW_QUALITY \(name) max channel difference=\(difference)/255")
        }
        let focus = PhotoRenderer(workingCacheLimit: 0, memoryTargetMB: 128)
        let focused = try #require(await focus.focusRegion(url: asset.url, adjustments: edited,
            center: CGPoint(x: 0.64, y: 0.37), viewportPixels: CGSize(width: 1800, height: 1200)))
        #expect(focused.image.cgImage.width == 1800 && focused.image.cgImage.height == 1200)
        await focus.releaseFullResolution()
        #expect(await focus.hasFullResolution == false)
    }
}
