import CoreImage
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import PerceptionEditor

private struct RepairSampler {
    let context = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    func pixel(_ image: CIImage, x: Int, y: Int) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: 4)
        context.render(image, toBitmap: &data, rowBytes: 4,
                       bounds: CGRect(x: x, y: y, width: 1, height: 1),
                       format: .RGBA8, colorSpace: space)
        return data
    }
}

struct RetouchTests {
    private func twoColorImage() -> CIImage {
        let red = CIImage(color: CIColor(red: 0.8, green: 0.1, blue: 0.1))
            .cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        let blue = CIImage(color: CIColor(red: 0.1, green: 0.2, blue: 0.8))
            .cropped(to: CGRect(x: 50, y: 0, width: 50, height: 100))
        return blue.composited(over: red).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    private func stroke(_ kind: RetouchKind, opacity: Double = 1) -> RetouchStroke {
        RetouchStroke(kind: kind, points: [NormalizedPoint(x: 0.75, y: 0.5)],
                      source: NormalizedPoint(x: 0.25, y: 0.5),
                      size: 0.18, feather: 0.25, opacity: opacity)
    }

    @Test func repairsPersistAndOlderAdjustmentsDefaultToNone() throws {
        var adjustments = PhotoAdjustments()
        adjustments.retouches = [stroke(.heal), stroke(.clone, opacity: 0.4)]
        let data = try JSONEncoder().encode(adjustments)
        #expect(try JSONDecoder().decode(PhotoAdjustments.self, from: data) == adjustments)
        #expect(try JSONDecoder().decode(PhotoAdjustments.self, from: Data("{}".utf8)).retouches.isEmpty)

        var target = PhotoAdjustments()
        target.retouches = [stroke(.clone)]
        #expect(target.applying(adjustments, groups: AdjustmentGroup.looks).retouches == target.retouches)
    }

    @Test func cloneCopiesSourceAndRespectsOpacityAndEnable() {
        let sampler = RepairSampler()
        let image = twoColorImage()
        let original = sampler.pixel(image, x: 75, y: 50)
        let cloned = sampler.pixel(RetouchRenderer.apply(image, strokes: [stroke(.clone)]), x: 75, y: 50)
        #expect(cloned[0] > original[0] + 100)
        #expect(cloned[2] + 100 < original[2])

        let half = sampler.pixel(RetouchRenderer.apply(image, strokes: [stroke(.clone, opacity: 0.5)]), x: 75, y: 50)
        #expect(half[0] > original[0] && half[0] < cloned[0])
        var disabled = stroke(.clone)
        disabled.isEnabled = false
        #expect(sampler.pixel(RetouchRenderer.apply(image, strokes: [disabled]), x: 75, y: 50) == original)
    }

    @Test func healingMatchesDestinationColorWhileKeepingSourceDetail() {
        let sampler = RepairSampler()
        let image = twoColorImage()
        let clone = sampler.pixel(RetouchRenderer.apply(image, strokes: [stroke(.clone)]), x: 75, y: 50)
        let heal = sampler.pixel(RetouchRenderer.apply(image, strokes: [stroke(.heal)]), x: 75, y: 50)
        let original = sampler.pixel(image, x: 75, y: 50)
        #expect(abs(Int(heal[0]) - Int(original[0])) < abs(Int(clone[0]) - Int(original[0])))
        #expect(abs(Int(heal[2]) - Int(original[2])) < abs(Int(clone[2]) - Int(original[2])))
    }

    @Test func gpuContextRendersHealingAndLeavesOutsidePixelsUntouched() {
        let context = CIContext(options: [.cacheIntermediates: false])
        let image = twoColorImage()
        let output = RetouchRenderer.apply(image, strokes: [stroke(.heal)])
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let repaired = context.createCGImage(output, from: output.extent, format: .RGBA8, colorSpace: space)
        #expect(repaired != nil)
        let sampler = RepairSampler()
        #expect(sampler.pixel(output, x: 5, y: 5) == sampler.pixel(image, x: 5, y: 5))
    }

    @Test func repairsEnterTheFullPhotoPipelineBeforeGeometry() {
        let sampler = RepairSampler()
        let image = twoColorImage()
        var adjustments = PhotoAdjustments()
        adjustments.retouches = [stroke(.clone)]
        adjustments.rotationQuarterTurns = 2
        let repaired = MediaColorRenderer.render(image, adjustments: adjustments, includesGeometry: true)
        let untouched = MediaColorRenderer.render(image, adjustments: PhotoAdjustments(rotationQuarterTurns: 2), includesGeometry: true)
        let changed = sampler.pixel(repaired, x: 25, y: 50)
        let old = sampler.pixel(untouched, x: 25, y: 50)
        #expect(changed[0] > old[0] + 80)
    }

    @Test func previewAndFullResolutionExportBothIncludeTheRepair() async throws {
        let files = try TempDirectory()
        let originalURL = files.url.appendingPathComponent("original.png")
        let outputURL = files.url.appendingPathComponent("repaired.png")
        let context = CIContext()
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        try context.writePNGRepresentation(of: twoColorImage(), to: originalURL,
                                           format: .RGBA8, colorSpace: space)

        var adjustments = PhotoAdjustments()
        adjustments.retouches = [stroke(.clone)]
        let renderer = PhotoRenderer(workingCacheLimit: 0)
        let preview = try #require(await renderer.preview(url: originalURL, adjustments: adjustments))
        let sampler = RepairSampler()
        #expect(sampler.pixel(CIImage(cgImage: preview.edited.cgImage), x: 75, y: 50)[0] > 150)

        try await renderer.export(url: originalURL, adjustments: adjustments, to: outputURL, type: .png)
        let exported = try #require(CIImage(contentsOf: outputURL))
        #expect(sampler.pixel(exported, x: 75, y: 50)[0] > 150)
        #expect(sampler.pixel(exported, x: 5, y: 5)[2] < 100)
    }

    @Test func largeHealingExportPreservesReferencePixelsWithABoundedRenderer() async throws {
        let files = try TempDirectory()
        let original = files.url.appendingPathComponent("large.png")
        let extent = CGRect(x: 0, y: 0, width: 6000, height: 4000)
        let image = twoColorImage().transformed(by: CGAffineTransform(scaleX: 60, y: 40)).cropped(to: extent)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        try CIContext().writePNGRepresentation(of: image, to: original, format: .RGBA8, colorSpace: space)
        var edits = PhotoAdjustments()
        edits.retouches = [RetouchStroke(kind: .heal, points: [NormalizedPoint(x: 0.64, y: 0.37)],
                                        source: NormalizedPoint(x: 0.72, y: 0.32), size: 0.035, feather: 0.6)]
        let renderer = PhotoRenderer(workingCacheLimit: 0, memoryTargetMB: 128)
        let destination = files.url.appendingPathComponent("healed.png")
        try await renderer.export(url: original, adjustments: edits, to: destination, type: .png, longEdgePixels: 2048)
        #expect(PhotoSourceLoader.dimensions(of: destination).map { [$0.width, $0.height] } == [2048, 1366])
        let referenceURL = files.url.appendingPathComponent("reference.png")
        try await PhotoRenderer(workingCacheLimit: 0, memoryTargetMB: nil).export(
            url: original, adjustments: edits, to: referenceURL, type: .png, longEdgePixels: 2048)
        let actual = try #require(CIImage(contentsOf: destination))
        let reference = try #require(CIImage(contentsOf: referenceURL))
        let sampler = RepairSampler()
        for point in [(100, 100), (1311, 860), (1474, 929)] {
            #expect(sampler.pixel(actual, x: point.0, y: point.1) == sampler.pixel(reference, x: point.0, y: point.1))
        }
    }
}

@MainActor
struct RetouchStoreTests {
    private func makeStore() -> (EditorStore, [MediaAsset]) {
        let defaults = UserDefaults(suiteName: "pme-retouch-\(UUID())")!
        let store = EditorStore(presetRepository: UserPresetRepository(defaults: defaults))
        let assets = (0 ..< 2).map { index in
            MediaAsset(url: URL(fileURLWithPath: "/Volumes/Test/repair-\(index).RW2"),
                       pixelWidth: 6000, pixelHeight: 4000)
        }
        store.project.media = assets
        store.select(assets[0])
        store.workspace = .photo
        return (store, assets)
    }

    @Test func oneHealStrokeIsOneUndoStepAndStaysWithItsPhoto() throws {
        let (store, assets) = makeStore()
        store.chooseRetouchTool(.heal)
        store.beginRetouch(at: NormalizedPoint(x: 0.5, y: 0.5))
        for step in 1 ... 12 {
            store.extendRetouch(to: NormalizedPoint(x: 0.5 + Double(step) * 0.01, y: 0.5))
        }
        store.endRetouchStroke()
        let stroke = try #require(store.selectedRetouch)
        #expect(stroke.points.count > 5)
        #expect(stroke.source != stroke.target)
        #expect(store.selectedHistory.map(\.name) == ["Start", "Heal"])
        store.select(assets[1])
        #expect(store.retouches.isEmpty)
        store.select(assets[0])
        #expect(store.retouches.count == 1)
        store.undoPhotoEdit()
        #expect(store.retouches.isEmpty)
    }

    @Test func cloneNeedsASourceAndMaskToolsCloseRetouching() {
        let (store, _) = makeStore()
        store.chooseRetouchTool(.clone)
        #expect(store.retouchPickingSource)
        store.beginRetouch(at: NormalizedPoint(x: 0.6, y: 0.6))
        #expect(store.retouches.isEmpty)
        store.setCloneSource(NormalizedPoint(x: 0.2, y: 0.2))
        store.beginRetouch(at: NormalizedPoint(x: 0.6, y: 0.6))
        store.endRetouchStroke()
        #expect(store.retouches.count == 1)
        #expect(store.selectedRetouch?.source == NormalizedPoint(x: 0.2, y: 0.2))
        store.chooseMaskTool(.brush)
        #expect(!store.isRetouchEditing)
        #expect(store.maskTool == .brush)
    }
}
