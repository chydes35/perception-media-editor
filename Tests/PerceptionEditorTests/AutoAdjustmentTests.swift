import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PerceptionEditor

private enum AutoFixture {
    static let space = CGColorSpace(name: CGColorSpace.sRGB)!
    // Keep fixture contexts local to each call on SDKs where CIContext is not Sendable.
    static var context: CIContext { CIContext() }

    static func gradient(low: Double, high: Double, cast: (Double, Double, Double) = (1, 1, 1)) -> CIImage {
        var buffer = [Float]()
        for _ in 0 ..< 64 {
            for x in 0 ..< 64 {
                let value = low + (high - low) * Double(x) / 63
                buffer += [Float(value * cast.0), Float(value * cast.1), Float(value * cast.2), 1]
            }
        }
        let data = buffer.withUnsafeBytes { Data($0) }
        return CIImage(bitmapData: data, bytesPerRow: 64 * 16, size: CGSize(width: 64, height: 64),
                       format: .RGBAf, colorSpace: space)
    }

    static func values(_ image: CIImage) -> (median: Double, range: Double, cast: Double, white: Double) {
        var buffer = [Float](repeating: 0, count: 64 * 64 * 4)
        context.render(image, toBitmap: &buffer, rowBytes: 64 * 16,
                       bounds: CGRect(x: 0, y: 0, width: 64, height: 64), format: .RGBAf, colorSpace: space)
        let luma = (0 ..< 4096).map { index -> Double in
            let i = index * 4
            return Double(0.2126 * buffer[i] + 0.7152 * buffer[i + 1] + 0.0722 * buffer[i + 2])
        }.sorted()
        let i = (32 * 64 + 32) * 4
        let cast = abs(log(Double(buffer[i] / buffer[i + 1]))) + abs(log(Double(buffer[i + 2] / buffer[i + 1])))
        return (luma[2048], luma[3686] - luma[409], cast, luma[4054])
    }

    static func png(_ image: CIImage, to url: URL) throws {
        let cg = try #require(context.createCGImage(image, from: image.extent))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cg, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    static func chromaticity(_ image: CIImage) -> (Double, Double) {
        var p = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &p, rowBytes: 16, bounds: CGRect(x: 32, y: 32, width: 1, height: 1),
                       format: .RGBAf, colorSpace: space)
        func linear(_ v: Float) -> Double {
            let value = Double(v)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let rgb = p.prefix(3).map(linear)
        let sum = rgb.reduce(0, +)
        return (rgb[0] / sum, rgb[2] / sum)
    }
}

struct AutoAdjustmentTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PERCEPTION_AUTO_QA_INPUTS"] != nil))
    func realPhotoPreviewAndExportCheck() async throws {
        let env = ProcessInfo.processInfo.environment
        let output = URL(fileURLWithPath: try #require(env["PERCEPTION_AUTO_QA_DIR"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let inputs = try #require(env["PERCEPTION_AUTO_QA_INPUTS"]).split(separator: "\n")
        let analyzer = AutoAdjustmentAnalyzer()
        for (index, path) in inputs.enumerated() {
            let url = URL(fileURLWithPath: String(path))
            let start = Date()
            let suggestion = try analyzer.analyze(url: url, current: .neutral)
            let elapsed = Date().timeIntervalSince(start)
            let applied = suggestion.applying(to: .neutral)
            let before = try #require(PhotoSourceLoader.load(url, maxDimension: 1024))
            let balanced = try #require(PhotoSourceLoader.load(url, maxDimension: 1024, raw: applied.raw))
            let after = MediaColorRenderer.render(balanced, adjustments: applied, includesGeometry: true)
            try AutoFixture.png(before, to: output.appendingPathComponent("photo-\(index + 1)-before.png"))
            try AutoFixture.png(after, to: output.appendingPathComponent("photo-\(index + 1)-after.png"))
            let settings = try JSONEncoder().encode(applied)
            try settings.write(to: output.appendingPathComponent("photo-\(index + 1)-settings.json"))
            print("AUTO QA photo \(index + 1): \(elapsed)s; EV \(applied.exposure), contrast \(applied.contrast), highlights \(applied.highlights), shadows \(applied.shadows), warmth \(applied.temperature), tint \(applied.tint), RAW WB \(String(describing: suggestion.rawWhiteBalance))")
            #expect(after.extent == before.extent)
            #expect(elapsed < 60)
            let second = try analyzer.analyze(url: url, current: applied)
            #expect(second == suggestion)
        }
    }

    @Test func darkAndBrightScenesReceiveDifferentEditsAndImproveBrightness() throws {
        let analyzer = AutoAdjustmentAnalyzer()
        let dark = AutoFixture.gradient(low: 0.03, high: 0.32)
        let bright = AutoFixture.gradient(low: 0.65, high: 0.99)
        let a = try analyzer.suggest(for: dark)
        let b = try analyzer.suggest(for: bright)
        let afterDark = AutoFixture.values(MediaColorRenderer.render(dark, adjustments: a.basic, includesGeometry: false))
        let afterBright = AutoFixture.values(MediaColorRenderer.render(bright, adjustments: b.basic, includesGeometry: false))
        #expect(a.basic.exposure > 0)
        #expect(b.basic.exposure < 0)
        #expect(afterDark.median > AutoFixture.values(dark).median + 0.06)
        #expect(afterBright.median < AutoFixture.values(bright).median - 0.06)
        #expect(a != b)
    }

    @Test func flatSceneGainsRangeAndBacklightingDoesNotBlowOutWhites() throws {
        let analyzer = AutoAdjustmentAnalyzer()
        let flat = AutoFixture.gradient(low: 0.39, high: 0.55)
        let flatEdit = try analyzer.suggest(for: flat)
        let after = AutoFixture.values(MediaColorRenderer.render(flat, adjustments: flatEdit.basic, includesGeometry: false))
        #expect(after.range > AutoFixture.values(flat).range + 0.015)
        let dark = AutoFixture.gradient(low: 0.02, high: 0.30)
        let white = CIImage(color: CIColor(red: 0.98, green: 0.98, blue: 0.98, colorSpace: AutoFixture.space)!)
            .cropped(to: CGRect(x: 48, y: 0, width: 16, height: 64))
        let backlit = white.composited(over: dark)
        let edit = try analyzer.suggest(for: backlit)
        let adjusted = AutoFixture.values(MediaColorRenderer.render(backlit, adjustments: edit.basic, includesGeometry: false))
        #expect(adjusted.median > AutoFixture.values(backlit).median + 0.04)
        #expect(adjusted.white <= 1.01)
    }

    @Test func neutralCastIsReducedAndStrongSceneColorsArePreserved() throws {
        let analyzer = AutoAdjustmentAnalyzer()
        for cast in [(1.08, 1.0, 0.92), (0.96, 1.08, 0.96)] {
            let image = AutoFixture.gradient(low: 0.32, high: 0.70, cast: cast)
            let suggestion = try analyzer.suggest(for: image)
            // Isolate WB to prove a cast correction, rather than a saturation reduction.
            var wb = PhotoAdjustments.neutral
            wb.temperature = suggestion.basic.temperature
            wb.tint = suggestion.basic.tint
            let after = AutoFixture.values(MediaColorRenderer.render(image, adjustments: wb, includesGeometry: false))
            #expect(after.cast < AutoFixture.values(image).cast * 0.85)
        }
        let blue = AutoFixture.gradient(low: 0.3, high: 0.7, cast: (0.4, 0.7, 1.2))
        let suggestion = try analyzer.suggest(for: blue)
        #expect(suggestion.basic.temperature == 0)
        #expect(suggestion.basic.tint == 0)
        #expect(suggestion.basic.saturation == 0)
    }

    @Test func toneSuggestionsPreserveSkinLikeAndBlueColorRatios() throws {
        let analyzer = AutoAdjustmentAnalyzer()
        for cast in [(1.0, 0.75, 0.55), (0.4, 0.7, 1.2)] {
            let image = AutoFixture.gradient(low: 0.1, high: 0.75, cast: cast)
            let suggestion = try analyzer.suggest(for: image)
            let result = MediaColorRenderer.render(image, adjustments: suggestion.basic, includesGeometry: false)
            let before = AutoFixture.chromaticity(image), after = AutoFixture.chromaticity(result)
            #expect(abs(after.0 - before.0) < 0.012)
            #expect(abs(after.1 - before.1) < 0.012)
            #expect(AutoFixture.values(result).median > AutoFixture.values(image).median)
        }
    }

    @Test func repeatedAutoIsIdenticalAndCropAffectsTheSuggestion() throws {
        let temp = try TempDirectory()
        let url = temp.url.appendingPathComponent("gradient.png")
        try AutoFixture.png(AutoFixture.gradient(low: 0.05, high: 0.95), to: url)
        let analyzer = AutoAdjustmentAnalyzer()
        var current = PhotoAdjustments.neutral
        current.exposure = 2
        current.temperature = -0.5
        current.raw.temperature = 7300
        let first = try analyzer.analyze(url: url, current: current)
        let second = try analyzer.analyze(url: url, current: first.applying(to: current))
        #expect(first == second)
        current.cropRect = CropRect(x: 0, y: 0, width: 0.35, height: 1)
        let cropped = try analyzer.analyze(url: url, current: current)
        #expect(cropped.basic.exposure > first.basic.exposure + 0.2)
    }

    @Test func blackWhiteAndTransparentImagesAreHandledWithoutNonfiniteValues() throws {
        let analyzer = AutoAdjustmentAnalyzer()
        for value in [0.0, 1.0] {
            let suggestion = try analyzer.suggest(for: AutoFixture.gradient(low: value, high: value))
            #expect(suggestion.basic.exposure.isFinite)
            #expect(abs(suggestion.basic.exposure) <= 1.4)
            #expect(suggestion.basic.temperature == 0)
        }
        let clear = CIImage(color: .clear).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        #expect(throws: AutoAdjustmentError.self) { try analyzer.suggest(for: clear) }
    }

    @Test(.enabled(if: RawSample.isAvailable))
    func rawAutoUsesCameraWhiteBalanceAndKeepsDetailSettings() throws {
        let analyzer = AutoAdjustmentAnalyzer()
        let url = try #require(RawSample.url)
        var current = PhotoAdjustments.neutral
        current.raw.colorNoiseReduction = 0.4
        let suggestion = try analyzer.analyze(url: url, current: current)
        let applied = suggestion.applying(to: current)
        #expect(applied.raw.colorNoiseReduction == 0.4)
        #expect(applied.exposure.isFinite)
        if let wb = suggestion.rawWhiteBalance {
            #expect((2000 ... 50000).contains(wb.temperature))
            #expect((-150 ... 150).contains(wb.tint))
        }
    }
}

@MainActor
struct AutoAdjustmentStoreTests {
    private func makeStore() -> EditorStore {
        let defaults = UserDefaults(suiteName: "pme-auto-\(UUID())")!
        let store = EditorStore(presetRepository: UserPresetRepository(defaults: defaults))
        let asset = MediaAsset(url: URL(fileURLWithPath: "/Volumes/Test/auto.jpg"))
        store.project.media = [asset]
        store.select(asset)
        store.workspace = .photo
        return store
    }

    private func complete(_ store: EditorStore, original: PhotoAdjustments, request: UUID? = nil) {
        var suggestion = AutoAdjustmentSuggestion()
        suggestion.basic.exposure = 0.6
        suggestion.basic.highlights = -0.4
        suggestion.basic.temperature = -0.1
        store.finishAutoAdjustment(suggestion, assetID: store.selectedAssetID!, sourceURL: store.selectedAsset!.url,
                                   projectID: store.project.id, generation: store.projectGeneration,
                                   requestID: request ?? store.autoRequestID, original: original)
    }

    @Test func autoIsOneUndoStepPreservesOtherEditsAndSurvivesSave() throws {
        let store = makeStore()
        var original = PhotoAdjustments.neutral
        original.cropRect = CropRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        original.masks = [LocalMask(shape: .brush(strokes: []))]
        original.sharpness = 0.4
        original.vibrance = 0.25
        original.raw.detail = 0.3
        store.selectedAdjustments = original
        store.isAnalyzingAuto = true
        complete(store, original: original)
        let applied = store.selectedAdjustments
        #expect(applied.exposure == 0.6)
        #expect(applied.cropRect == original.cropRect)
        #expect(applied.masks == original.masks)
        #expect(applied.sharpness == original.sharpness)
        #expect(applied.vibrance == original.vibrance)
        #expect(applied.raw.detail == original.raw.detail)
        #expect(store.selectedHistory.map(\.name) == ["Start", "Auto"])
        let restored = try ProjectDocument().project(from: ProjectDocument().data(for: store.project))
        #expect(restored.adjustmentsByAssetID[store.selectedAssetID!] == applied)
        store.undoPhotoEdit()
        #expect(store.selectedAdjustments == original)
        store.redoPhotoEdit()
        #expect(store.selectedAdjustments == applied)
        store.isAnalyzingAuto = true
        complete(store, original: applied)
        #expect(store.selectedHistory.count == 2)
    }

    @Test func cancelNavigationAndManualEditsRejectStaleResults() {
        let store = makeStore()
        let original = store.selectedAdjustments
        store.isAnalyzingAuto = true
        let canceled = store.autoRequestID
        #expect(store.handleKey("\u{1B}"))
        complete(store, original: original, request: canceled)
        #expect(store.selectedAdjustments == original)
        store.isAnalyzingAuto = true
        let beforeEdit = store.autoRequestID
        store.updateAdjustments { $0.exposure = 1.1 }
        complete(store, original: original, request: beforeEdit)
        #expect(store.selectedAdjustments.exposure == 1.1)
        store.isAnalyzingAuto = true
        store.workspace = .library
        #expect(!store.isAnalyzingAuto)
        store.workspace = .photo
        store.isAnalyzingAuto = true
        store.selectedAssetID = UUID()
        #expect(!store.isAnalyzingAuto)
    }

    @Test func relinkingOrReplacingTheProjectRejectsAnOldPhotoSuggestion() {
        let store = makeStore()
        let asset = store.selectedAsset!
        let projectID = store.project.id
        let original = store.selectedAdjustments
        var suggestion = AutoAdjustmentSuggestion()
        suggestion.basic.exposure = 0.8
        store.isAnalyzingAuto = true
        store.project.media[0].url = URL(fileURLWithPath: "/Volumes/Test/relinked.jpg")
        store.finishAutoAdjustment(suggestion, assetID: asset.id, sourceURL: asset.url, projectID: projectID, generation: store.projectGeneration,
                                   requestID: store.autoRequestID, original: original)
        #expect(store.selectedAdjustments == original)
        store.isAnalyzingAuto = true
        store.project.id = UUID()
        store.finishAutoAdjustment(suggestion, assetID: asset.id, sourceURL: store.selectedAsset!.url, projectID: projectID, generation: store.projectGeneration,
                                   requestID: store.autoRequestID, original: original)
        #expect(store.selectedAdjustments == original)
        #expect(store.selectedHistory.isEmpty)
    }
}
