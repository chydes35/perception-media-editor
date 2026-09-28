import CoreImage
import CoreML
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PerceptionEditor

private enum SkyFixture {
    static let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    static func topMask() throws -> CIImage {
        let labels = try MLMultiArray(shape: [24, 32], dataType: .int32)
        for y in 0 ..< 24 {
            for x in 0 ..< 32 { labels[[NSNumber(value: y), NSNumber(value: x)]] = NSNumber(value: y < 8 ? 187 : 158) }
        }
        return try SkyAnalyzer.labelMask(labels, skyID: 187)
    }

    static func png(_ image: CIImage) throws -> Data {
        let data = NSMutableData()
        let cg = try #require(context.createCGImage(image, from: image.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray()))
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cg, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static func weight(_ image: CIImage, x: Double, y: Double) -> Int {
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(image, toBitmap: &pixel, rowBytes: 4,
                       bounds: CGRect(x: image.extent.minX + x * image.extent.width,
                                      y: image.extent.minY + (1 - y) * image.extent.height, width: 1, height: 1),
                       format: .RGBA8, colorSpace: nil)
        return Int(pixel[0])
    }
}

struct SkySelectionTests {
    @Test func semanticRowsStayAtTheTopAndOtherClassesAreExcluded() throws {
        let image = try SkyFixture.topMask()
        #expect(SkyFixture.weight(image, x: 0.5, y: 0.1) > 245)
        #expect(SkyFixture.weight(image, x: 0.5, y: 0.8) < 10)
        var raster = [UInt8](repeating: 0, count: 32 * 24)
        SkyFixture.context.render(image, toBitmap: &raster, rowBytes: 32, bounds: image.extent, format: .L8, colorSpace: nil)
        let restored = CIImage(bitmapData: Data(raster), bytesPerRow: 32, size: image.extent.size, format: .L8, colorSpace: nil)
        #expect(SkyFixture.weight(restored, x: 0.5, y: 0.1) > 245)
        #expect(SkyFixture.weight(restored, x: 0.5, y: 0.8) < 10)
        let labels = try MLMultiArray(shape: [24, 32], dataType: .int32)
        for i in 0 ..< labels.count { labels[i] = 158 }
        #expect(throws: SkySelectionError.self) { try SkyAnalyzer.labelMask(labels, skyID: 187) }
    }

    @Test func guidedEdgesFollowTheImageAndKeepUniformMasksUniform() {
        let width = 64, height = 16
        let guide = (0 ..< width * height).map { Float($0 % width >= 32 ? 1 : 0) }
        let mask = (0 ..< width * height).map { min(1, max(0, Float($0 % width - 28) / 8)) }
        let refined = SkyEdgeRefiner.refine(mask: mask, guide: guide, width: width, height: height, radius: 8, epsilon: 0.001)
        let row = 8 * width
        #expect(refined[row + 30] < mask[row + 30])
        #expect(refined[row + 33] > mask[row + 33])
        #expect(refined[row + 33] - refined[row + 30] > 0.7)
        for value: Float in [0, 1] {
            let constant = [Float](repeating: value, count: guide.count)
            let output = SkyEdgeRefiner.refine(mask: constant, guide: guide, width: width, height: height, radius: 8, epsilon: 0.001)
            #expect(output.allSatisfy { abs($0 - value) < 0.001 })
        }
    }

    @Test func skyAndCorrectionsSurviveProjectSaveAndDoNotSyncToAnotherPhoto() throws {
        let sky = SubjectMask(png: try SkyFixture.png(SkyFixture.topMask()), strokes: [
            BrushStroke(points: [NormalizedPoint(x: 0.4, y: 0.2)], size: 0.04, feather: 0.3, isErase: true)
        ], edgeShift: -0.001, edgeFeather: 0.001, edgeContrast: 0.2)
        let asset = MediaAsset(url: URL(fileURLWithPath: "/tmp/sky.jpg"))
        var project = EditorProject.starter
        project.media = [asset]
        var photo = PhotoAdjustments()
        photo.masks = [LocalMask(shape: .sky(sky))]
        project.adjustmentsByAssetID[asset.id] = photo
        let decoded = try ProjectDocument().project(from: ProjectDocument().data(for: project))
        #expect(decoded.schemaVersion == 10)
        #expect(decoded.adjustmentsByAssetID[asset.id]?.masks == photo.masks)
        #expect(PhotoAdjustments().applying(photo, groups: [.masks]).masks.isEmpty)
    }

    @Test func skyFollowsRotationCropAndTheFullExportPipeline() async throws {
        let png = try SkyFixture.png(SkyFixture.topMask())
        var mask = LocalMask(shape: .sky(SubjectMask(png: png)))
        mask.adjustments.exposure = -1
        let source = CIImage(color: CIColor(red: 0.7, green: 0.7, blue: 0.7))
            .cropped(to: CGRect(x: 0, y: 0, width: 640, height: 480))
        var adjustments = PhotoAdjustments()
        adjustments.rotationQuarterTurns = 1
        adjustments.cropRect = CropRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
        let geometry = ImageGeometry(sourceSize: source.extent.size, adjustments: adjustments)
        let skyPoint = geometry.finished(fromSource: NormalizedPoint(x: 0.5, y: 0.1))
        let landPoint = geometry.finished(fromSource: NormalizedPoint(x: 0.5, y: 0.8))
        let base = MediaColorRenderer.render(source, adjustments: adjustments, includesGeometry: true)
        adjustments.masks = [mask]
        let result = MediaColorRenderer.render(source, adjustments: adjustments, includesGeometry: true)
        #expect(SkyFixture.weight(result, x: skyPoint.x, y: skyPoint.y) < SkyFixture.weight(base, x: skyPoint.x, y: skyPoint.y) - 30)
        #expect(abs(SkyFixture.weight(result, x: landPoint.x, y: landPoint.y) - SkyFixture.weight(base, x: landPoint.x, y: landPoint.y)) < 2)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sky-export-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("source.png")
        let output = directory.appendingPathComponent("sky.png")
        let before = directory.appendingPathComponent("before.png")
        try SkyFixture.png(source).write(to: input)
        let renderer = PhotoRenderer(workingCacheLimit: 0)
        try await renderer.export(url: input, adjustments: adjustments, to: output, type: .png)
        adjustments.masks = []
        try await renderer.export(url: input, adjustments: adjustments, to: before, type: .png)
        let saved = try #require(CIImage(contentsOf: output))
        let unmasked = try #require(CIImage(contentsOf: before))
        #expect(abs(saved.extent.width - geometry.finishedSize.width) <= 1)
        #expect(abs(saved.extent.height - geometry.finishedSize.height) <= 1)
        #expect(SkyFixture.weight(saved, x: skyPoint.x, y: skyPoint.y) < SkyFixture.weight(unmasked, x: skyPoint.x, y: skyPoint.y) - 30)
        #expect(abs(SkyFixture.weight(saved, x: landPoint.x, y: landPoint.y) - SkyFixture.weight(unmasked, x: landPoint.x, y: landPoint.y)) < 2)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PERCEPTION_SKY_MODEL_PATH"] != nil))
    func actualModelRejectsTheIndoorTwoPersonPhoto() throws {
        let modelPath = try #require(ProcessInfo.processInfo.environment["PERCEPTION_SKY_MODEL_PATH"])
        let photo = URL(fileURLWithPath: "/Volumes/ExSSD1/Masterball Collectibles/Masterball Collectibles/collinphoto.jpg")
        guard FileManager.default.fileExists(atPath: photo.path) else { return }
        let model = try SkyAnalyzer.loadModel(at: URL(fileURLWithPath: modelPath))
        #expect(throws: SkySelectionError.noSky) { try SkyAnalyzer.analyze(url: photo, model: model) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PERCEPTION_SKY_TEST_PHOTO"] != nil))
    func actualSkyPhotoProducesAnAlignedPortableMask() throws {
        let modelPath = try #require(ProcessInfo.processInfo.environment["PERCEPTION_SKY_MODEL_PATH"])
        let photo = try #require(ProcessInfo.processInfo.environment["PERCEPTION_SKY_TEST_PHOTO"])
        let model = try SkyAnalyzer.loadModel(at: URL(fileURLWithPath: modelPath))
        if let output = ProcessInfo.processInfo.environment["PERCEPTION_SKY_PHOTO_PREVIEW"],
           let source = PhotoSourceLoader.load(URL(fileURLWithPath: photo), maxDimension: 1536) {
            try CIContext().writePNGRepresentation(of: source, to: URL(fileURLWithPath: output), format: .RGBA8,
                                                   colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        let png = try SkyAnalyzer.analyze(url: URL(fileURLWithPath: photo), model: model)
        let image = try #require(CIImage(data: png, options: [.colorSpace: NSNull()]))
        #expect(max(image.extent.width, image.extent.height) <= SkyAnalyzer.maximumMaskDimension + 1)
        if let point = ProcessInfo.processInfo.environment["PERCEPTION_SKY_TEST_POINT"]?.split(separator: ",").compactMap({ Double($0) }), point.count == 2 {
            #expect(SkyFixture.weight(image, x: point[0], y: point[1]) > 150)
        }
        if let point = ProcessInfo.processInfo.environment["PERCEPTION_SKY_EXCLUDED_POINT"]?.split(separator: ",").compactMap({ Double($0) }), point.count == 2 {
            #expect(SkyFixture.weight(image, x: point[0], y: point[1]) < 20)
        }
        if let output = ProcessInfo.processInfo.environment["PERCEPTION_SKY_MASK_OUTPUT"] {
            try png.write(to: URL(fileURLWithPath: output), options: .atomic)
        }
    }
}

@MainActor
struct SkyStoreTests {
    private func store() -> (EditorStore, MediaAsset) {
        let defaults = UserDefaults(suiteName: "pme-sky-\(UUID())")!
        let store = EditorStore(presetRepository: UserPresetRepository(defaults: defaults))
        let asset = MediaAsset(url: URL(fileURLWithPath: "/tmp/sky-store.jpg"), pixelWidth: 640, pixelHeight: 480)
        store.project.media = [asset]
        store.select(asset)
        store.workspace = .photo
        return (store, asset)
    }

    @Test func selectionIsOneUndoStepAndBrushCorrectionsKeepTheSkyKind() throws {
        let (store, asset) = store()
        let request = UUID()
        store.skyRequestID = request
        store.isAnalyzingSky = true
        store.finishSkySelection(png: try SkyFixture.png(SkyFixture.topMask()), assetID: asset.id, requestID: request)
        #expect(store.masks.count == 1 && store.selectedMask?.shape.kindName == "Sky")
        #expect(store.history[asset.id]?.last?.name == "Select Sky")
        store.undoPhotoEdit()
        #expect(store.masks.isEmpty)
        store.redoPhotoEdit()
        store.beginSubjectRefinement(erasing: true)
        store.beginBrushStroke(at: NormalizedPoint(x: 0.4, y: 0.2), erasing: false)
        store.endBrushStroke()
        let mask = try #require(store.selectedMask)
        #expect(mask.shape.kindName == "Sky" && mask.shape.rasterSelection?.strokes.last?.isErase == true)
        store.undoPhotoEdit()
        #expect(store.masks.count == 1 && store.masks[0].shape.rasterSelection?.strokes.isEmpty == true)
    }

    @Test func canceledAndNavigatedRequestsCannotAddAMask() {
        let (store, asset) = store()
        let request = UUID()
        store.skyRequestID = request
        store.isAnalyzingSky = true
        #expect(store.handleKey("\u{1B}"))
        store.finishSkySelection(png: Data([1]), assetID: asset.id, requestID: request)
        #expect(store.masks.isEmpty && !store.isAnalyzingSky)
        let next = UUID()
        store.skyRequestID = next
        store.isAnalyzingSky = true
        let other = MediaAsset(url: URL(fileURLWithPath: "/tmp/other-sky.jpg"))
        store.project.media.append(other)
        store.select(other)
        store.finishSkySelection(png: Data([1]), assetID: asset.id, requestID: next)
        #expect(store.masks.isEmpty && !store.isAnalyzingSky)
    }
}
