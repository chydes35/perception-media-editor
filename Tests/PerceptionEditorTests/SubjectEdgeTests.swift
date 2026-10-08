import AppKit
import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PerceptionEditor

private enum SubjectFixture {
    static let extent = CGRect(x: 0, y: 0, width: 512, height: 512)

    static func png(_ value: (Int, Int) -> UInt8) throws -> Data {
        var pixels = [UInt8](repeating: 0, count: 512 * 512)
        for y in 0 ..< 512 {
            for x in 0 ..< 512 { pixels[y * 512 + x] = value(x, y) }
        }
        let image = CIImage(bitmapData: Data(pixels), bytesPerRow: 512,
                            size: extent.size, format: .L8, colorSpace: nil)
        let cg = try #require(context.createCGImage(image, from: extent, format: .L8,
                                                   colorSpace: CGColorSpaceCreateDeviceGray()))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cg, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    static func weight(_ image: CIImage, x: Double, y: Double = 0.5) -> Int {
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(image, toBitmap: &pixel, rowBytes: 4,
                       bounds: CGRect(x: image.extent.minX + x * image.extent.width,
                                      y: image.extent.minY + y * image.extent.height, width: 1, height: 1),
                       format: .RGBA8, colorSpace: nil)
        return Int(pixel[0])
    }
}

struct SubjectEdgeTests {
    @Test func edgeShiftContractsAndExpandsWithoutMovingTheSubject() throws {
        let png = try SubjectFixture.png { x, y in
            (128 ..< 384).contains(x) && (64 ..< 448).contains(y) ? 255 : 0
        }
        let base = SubjectMaskRenderer.image(SubjectMask(png: png), extent: SubjectFixture.extent)
        let shrink = SubjectMaskRenderer.image(SubjectMask(png: png, edgeShift: -0.005), extent: SubjectFixture.extent)
        let expand = SubjectMaskRenderer.image(SubjectMask(png: png, edgeShift: 0.005), extent: SubjectFixture.extent)
        #expect(SubjectFixture.weight(base, x: 129.0 / 512) == 255)
        #expect(SubjectFixture.weight(shrink, x: 129.0 / 512) < 10)
        #expect(SubjectFixture.weight(expand, x: 126.0 / 512) > 245)
        #expect(SubjectFixture.weight(shrink, x: 0.5) == 255)
        #expect(SubjectFixture.weight(expand, x: 0.1) == 0)
    }

    @Test func featherSoftensEdgesAndMatchesExportAtLargerSizes() throws {
        let png = try SubjectFixture.png { x, _ in x >= 128 ? 255 : 0 }
        let subject = SubjectMask(png: png, edgeShift: -0.002, edgeFeather: 0.005)
        let preview = SubjectMaskRenderer.image(subject, extent: SubjectFixture.extent)
        let export = SubjectMaskRenderer.image(subject, extent: CGRect(x: 23, y: 41, width: 4096, height: 4096))
        let outside = SubjectFixture.weight(preview, x: 126.0 / 512)
        let inside = SubjectFixture.weight(preview, x: 130.0 / 512)
        #expect(outside > 0 && outside < 128)
        #expect(inside > 128 && inside < 255)
        for x in [0.1, 126.0 / 512, 130.0 / 512, 0.5, 0.99] {
            // Compare centers of corresponding source-mask pixels.
            let a = SubjectFixture.weight(preview, x: x + 0.5 / 512)
            let b = SubjectFixture.weight(export, x: x + 0.5 / 512)
            #expect(abs(a - b) <= 12)
        }
        #expect(SubjectFixture.weight(preview, x: 0.999) == 255, "image-border subjects must not fade")
    }

    @Test func neutralEdgesPreserveTranslucencyAndContrastCanFirmThem() throws {
        let png = try SubjectFixture.png { x, _ in
            x < 170 ? 51 : (x < 340 ? 128 : 204)
        }
        let base = SubjectMaskRenderer.image(SubjectMask(png: png), extent: SubjectFixture.extent)
        let firm = SubjectMaskRenderer.image(SubjectMask(png: png, edgeContrast: 1), extent: SubjectFixture.extent)
        #expect(SubjectFixture.weight(base, x: 0.1) == 51)
        #expect(SubjectFixture.weight(base, x: 0.5) == 128)
        #expect(SubjectFixture.weight(base, x: 0.9) == 204)
        #expect(SubjectFixture.weight(firm, x: 0.1) == 0)
        #expect(abs(SubjectFixture.weight(firm, x: 0.5) - 128) <= 3)
        #expect(SubjectFixture.weight(firm, x: 0.9) == 255)
    }

    @Test func unionContainsPeopleAndObjectsAndPreservesSoftWeights() throws {
        let left = try SubjectFixture.png { x, _ in x < 170 ? 204 : 0 }
        let right = try SubjectFixture.png { x, _ in x > 340 ? 128 : 0 }
        let png = try SubjectAnalyzer.unionPNG([left, right])
        let union = SubjectMaskRenderer.image(SubjectMask(png: png), extent: SubjectFixture.extent)
        #expect(SubjectFixture.weight(union, x: 0.1) == 204)
        #expect(SubjectFixture.weight(union, x: 0.5) == 0)
        #expect(SubjectFixture.weight(union, x: 0.9) == 128)
    }

    @Test func schemaEightSubjectMasksLoadWithNeutralEdges() throws {
        var project = EditorProject.starter
        let asset = MediaAsset(url: URL(fileURLWithPath: "/tmp/old-subject.jpg"))
        project.media = [asset]
        var adjustments = PhotoAdjustments()
        adjustments.masks = [LocalMask(shape: .subject(SubjectMask(png: Data([1, 2, 3]))))]
        project.adjustmentsByAssetID[asset.id] = adjustments
        func legacy(_ value: Any) -> Any {
            if var object = value as? [String: Any] {
                for key in ["edgeShift", "edgeFeather", "edgeContrast"] { object.removeValue(forKey: key) }
                return object.mapValues(legacy)
            }
            if let array = value as? [Any] { return array.map(legacy) }
            return value
        }
        var json = try #require(legacy(JSONSerialization.jsonObject(with: ProjectDocument().data(for: project))) as? [String: Any])
        json["schemaVersion"] = 8
        let old = try ProjectDocument().project(from: JSONSerialization.data(withJSONObject: json))
        #expect(old.adjustmentsByAssetID[asset.id]?.masks == adjustments.masks)
    }
}

@MainActor
struct SubjectPreviewTests {
    @Test func reopeningPickerRestoresOverviewAndLatestHoverWins() async throws {
        let all = try SubjectFixture.png { x, _ in x < 170 || x > 340 ? 255 : 0 }
        let left = try SubjectFixture.png { x, _ in x < 170 ? 255 : 0 }
        let right = try SubjectFixture.png { x, _ in x > 340 ? 255 : 0 }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("subject-preview-\(UUID()).png")
        try all.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let defaults = UserDefaults(suiteName: "pme-subject-preview-\(UUID())")!
        let store = EditorStore(presetRepository: UserPresetRepository(defaults: defaults))
        let asset = MediaAsset(url: url, pixelWidth: 512, pixelHeight: 512)
        store.project.media = [asset]
        store.select(asset)
        store.workspace = .photo
        store.subjectAnalysis = SubjectAnalysis(candidates: [
            SubjectCandidate(id: 1, kind: .person, png: left, pixelCount: 100),
            SubjectCandidate(id: 2, kind: .person, png: right, pixelCount: 100)
        ], allSubjectsPNG: all, personLabels: nil, foregroundLabels: nil)

        func awaitOverlay() async throws {
            for _ in 0 ..< 200 {
                if store.subjectSelectionOverlay != nil && store.subjectOverlayTask == nil { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            Issue.record("Subject preview did not finish")
        }
        store.startSubjectSelection()
        try await awaitOverlay()
        #expect(store.subjectSelectionOverlay != nil)
        store.selectSubjectCandidate(1)
        #expect(!store.isPickingSubject && store.subjectSelectionOverlay == nil)
        store.startSubjectSelection()
        try await awaitOverlay()
        #expect(store.subjectSelectionOverlay != nil && store.highlightedSubjectID == nil)
        let maskCount = store.masks.count
        store.previewSubjectCandidate(1)
        store.previewSubjectCandidate(2)
        try await awaitOverlay()
        #expect(store.highlightedSubjectID == 2)
        let cg = try #require(store.subjectSelectionOverlay?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let image = CIImage(cgImage: cg, options: [.colorSpace: NSNull()])
        func alpha(_ x: Double) -> Int {
            var pixel = [UInt8](repeating: 0, count: 4)
            SubjectFixture.context.render(image, toBitmap: &pixel, rowBytes: 4,
                                          bounds: CGRect(x: x * image.extent.width, y: image.extent.height / 2, width: 1, height: 1),
                                          format: .RGBA8, colorSpace: nil)
            return Int(pixel[3])
        }
        #expect(alpha(0.1) < 10 && alpha(0.9) > 245)
        #expect(store.masks.count == maskCount, "previewing must not add edits")
        store.previewSubjectCandidate(1)
        store.cancelSubjectSelection()
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.subjectSelectionOverlay == nil && store.highlightedSubjectID == nil)
        #expect(store.subjectOverlayCache.isEmpty && store.subjectOverlayTask == nil)
    }
}
