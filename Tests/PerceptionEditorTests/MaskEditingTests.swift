import CoreGraphics
import ImageIO
import Foundation
import Testing
@testable import PerceptionEditor

@MainActor
struct MaskStoreTests {
    private func makeStore(photos: Int = 2, withSize: Bool = true) -> (EditorStore, [MediaAsset]) {
        let suite = "pme-tests-\(UUID().uuidString)"
        let store = EditorStore(presetRepository: UserPresetRepository(defaults: UserDefaults(suiteName: suite)!))
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        let assets = (0 ..< photos).map { index in
            MediaAsset(
                url: URL(fileURLWithPath: "/Volumes/Test/P\(1000 + index).RW2"),
                captureDate: base.addingTimeInterval(Double(index) * 10),
                pixelWidth: withSize ? 6000 : nil, pixelHeight: withSize ? 4000 : nil
            )
        }
        store.project.media = assets
        for asset in assets { store.project.adjustmentsByAssetID[asset.id] = .neutral }
        store.select(store.allPhotos[0])
        return (store, assets)
    }

    private func point(_ x: Double, _ y: Double) -> NormalizedPoint { NormalizedPoint(x: x, y: y) }

    // MARK: Adding and removing

    @Test func addingAMaskSelectsItAndStartsWithAVisibleChange() throws {
        let (store, _) = makeStore()
        let id = try #require(store.addMask(.linear(start: point(0.5, 0.1), end: point(0.5, 0.5))))

        #expect(store.selectedMaskID == id)
        #expect(store.masks.count == 1)
        #expect(store.selectedMask?.isActive == true, "a fresh mask already does something")
        #expect(store.isMaskEditing)
    }

    @Test func deletingDuplicatingAndResettingAMask() throws {
        let (store, _) = makeStore()
        let id = try #require(store.addMask(.radial(center: point(0.5, 0.5), radiusX: 0.2, radiusY: 0.1, rotation: 0, feather: 0.5)))
        store.updateMask(id) { $0.name = "Face"; $0.adjustments.exposure = 0.7 }

        store.duplicateMask(id)
        #expect(store.masks.count == 2)
        let copy = try #require(store.selectedMask)
        #expect(copy.id != id && copy.name == "Face copy" && copy.adjustments.exposure == 0.7)

        store.resetMaskAdjustments(copy.id)
        #expect(store.selectedMask?.adjustments.isNeutral == true)
        #expect(store.masks.first { $0.id == id }?.adjustments.exposure == 0.7, "the original is untouched")

        store.deleteMask(copy.id)
        #expect(store.masks.map(\.id) == [id])
        #expect(store.selectedMaskID == nil)
    }

    @Test func maskNamesAreNumberedWithinTheirKind() throws {
        let (store, _) = makeStore()
        store.addMask(.linear(start: point(0, 0), end: point(0, 1)))
        store.addMask(.radial(center: point(0.5, 0.5), radiusX: 0.1, radiusY: 0.1, rotation: 0, feather: 0))
        store.addMask(.linear(start: point(0, 0), end: point(1, 1)))
        let names = store.masks.map { store.displayName(for: $0) }
        #expect(names == ["Linear Gradient 1", "Radial Gradient 1", "Linear Gradient 2"])
    }

    // MARK: Drawing gradients

    @Test func drawingAGradientIsOneUndoStepWithAClearHistoryName() throws {
        let (store, _) = makeStore()
        store.chooseMaskTool(.linear)
        let id = try #require(store.beginGradient(.linear, at: point(0.5, 0.2)))
        for step in 1 ... 10 {
            store.updateMask(id) { $0.shape = .linear(start: NormalizedPoint(x: 0.5, y: 0.2), end: NormalizedPoint(x: 0.5, y: 0.2 + Double(step) * 0.05)) }
        }
        store.endMaskDrag()

        #expect(store.masks.count == 1)
        #expect(store.maskTool == .none, "the tool closes after one gradient")
        #expect(store.selectedMaskID == id)
        #expect(store.selectedHistory.map(\.name) == ["Start", "Linear Gradient"])

        store.undoPhotoEdit()
        #expect(store.masks.isEmpty, "one undo removes the whole gradient")
    }

    @Test func draggingAHandleIsOneUndoStepThatRestoresTheOldShape() throws {
        let (store, _) = makeStore()
        let id = try #require(store.addMask(.linear(start: point(0.5, 0.2), end: point(0.5, 0.6))))
        let before = try #require(store.selectedMask?.shape)

        store.beginMaskDrag(label: "Move gradient")
        for step in 1 ... 8 {
            store.updateMask(id) { $0.shape = .linear(start: NormalizedPoint(x: 0.5, y: 0.2 + Double(step) * 0.02), end: NormalizedPoint(x: 0.5, y: 0.6)) }
        }
        store.endMaskDrag()

        #expect(store.selectedHistory.last?.name == "Move gradient")
        store.undoPhotoEdit()
        #expect(store.selectedMask?.shape == before)
    }

    @Test func aRadialGradientKeepsItsRotationAndFeatherWhileResized() throws {
        let (store, _) = makeStore()
        let id = try #require(store.beginGradient(.radial, at: point(0.4, 0.4)))
        store.updateMask(id) { $0.shape = .radial(center: NormalizedPoint(x: 0.4, y: 0.4), radiusX: 0.2, radiusY: 0.2, rotation: 30, feather: 0.7) }
        store.endMaskDrag()

        guard case .radial(_, let rx, _, let rotation, let feather) = try #require(store.selectedMask?.shape) else {
            Issue.record("expected a radial gradient"); return
        }
        #expect(rx == 0.2 && rotation == 30 && feather == 0.7)
    }

    // MARK: Painting

    @Test func aBrushStrokeCreatesABrushMaskAndIsOneUndoStep() throws {
        let (store, _) = makeStore()
        store.chooseMaskTool(.brush)
        store.brushSize = 0.08
        store.brushFeather = 0.4

        store.beginBrushStroke(at: point(0.3, 0.3), erasing: false)
        for step in 1 ... 20 {
            store.extendBrushStroke(to: point(0.3 + Double(step) * 0.02, 0.3))
        }
        store.endBrushStroke()

        #expect(store.maskTool == .brush, "the brush stays active for the next stroke")
        guard case .brush(let strokes) = try #require(store.selectedMask?.shape) else { Issue.record("expected a brush"); return }
        #expect(strokes.count == 1 && strokes[0].points.count > 10)
        #expect(strokes[0].size == 0.08 && strokes[0].feather == 0.4 && !strokes[0].isErase)
        #expect(store.selectedHistory.map(\.name) == ["Start", "Brush"])

        store.undoPhotoEdit()
        #expect(store.masks.isEmpty)
    }

    @Test func laterStrokesJoinTheSameMaskAndEachIsItsOwnUndoStep() throws {
        let (store, _) = makeStore()
        store.chooseMaskTool(.brush)
        store.beginBrushStroke(at: point(0.2, 0.2), erasing: false)
        store.extendBrushStroke(to: point(0.4, 0.2))
        store.endBrushStroke()
        store.beginBrushStroke(at: point(0.2, 0.6), erasing: false)
        store.extendBrushStroke(to: point(0.4, 0.6))
        store.endBrushStroke()

        #expect(store.masks.count == 1)
        guard case .brush(let both) = try #require(store.selectedMask?.shape) else { return }
        #expect(both.count == 2)

        store.undoPhotoEdit()
        guard case .brush(let one) = try #require(store.selectedMask?.shape) else { return }
        #expect(one.count == 1, "undo removes only the last stroke")
    }

    @Test func erasingNeedsABrushMaskAndMarksItsStrokes() throws {
        let (store, _) = makeStore()
        store.chooseMaskTool(.brush)

        store.beginBrushStroke(at: point(0.5, 0.5), erasing: true)
        #expect(store.masks.isEmpty, "there is nothing to erase from yet")
        #expect(!store.isMaskInteracting)
        #expect(!store.canUndoPhotoEdit)

        store.beginBrushStroke(at: point(0.5, 0.5), erasing: false)
        store.endBrushStroke()
        store.brushErasing = true
        store.beginBrushStroke(at: point(0.5, 0.5), erasing: false)
        store.endBrushStroke()

        guard case .brush(let strokes) = try #require(store.selectedMask?.shape) else { return }
        #expect(strokes.map(\.isErase) == [false, true])
    }

    @Test func tinyMovementsDoNotBloatAStroke() throws {
        let (store, _) = makeStore()
        store.chooseMaskTool(.brush)
        store.brushSize = 0.1
        store.beginBrushStroke(at: point(0.5, 0.5), erasing: false)
        for _ in 0 ..< 100 { store.extendBrushStroke(to: point(0.5001, 0.5001)) }
        store.endBrushStroke()

        guard case .brush(let strokes) = try #require(store.selectedMask?.shape) else { return }
        #expect(strokes[0].points.count == 1)
    }

    // MARK: Tools and keys

    @Test func toolsToggleAndStartFreshOrContinue() throws {
        let (store, _) = makeStore()
        store.chooseMaskTool(.linear)
        #expect(store.maskTool == .linear)
        store.chooseMaskTool(.linear)
        #expect(store.maskTool == .none, "choosing it again closes it")

        let gradient = try #require(store.addMask(.linear(start: point(0, 0), end: point(0, 1))))
        store.chooseMaskTool(.brush)
        #expect(store.selectedMaskID == nil, "a gradient is not continued with the brush")
        store.beginBrushStroke(at: point(0.5, 0.5), erasing: false)
        store.endBrushStroke()
        let brush = try #require(store.selectedMaskID)
        #expect(brush != gradient)

        store.chooseMaskTool(.none)
        store.chooseMaskTool(.brush)
        #expect(store.selectedMaskID == brush, "painting resumes on the selected brush")
    }

    @Test func selectingAMaskClosesGradientToolsButKeepsAnActiveBrush() throws {
        let (store, _) = makeStore()
        let gradient = try #require(store.addMask(.linear(start: point(0, 0), end: point(0, 1))))
        store.chooseMaskTool(.brush)
        store.beginBrushStroke(at: point(0.5, 0.5), erasing: false)
        store.endBrushStroke()
        let brush = try #require(store.selectedMaskID)

        store.selectMask(brush)
        #expect(store.maskTool == .brush)
        store.selectMask(gradient)
        #expect(store.maskTool == .none)
    }

    @Test func keysResizeTheBrushToggleTheOverlayAndEscapeClosesTools() {
        let (store, _) = makeStore()
        store.workspace = .photo
        store.chooseMaskTool(.brush)
        store.brushSize = 0.06

        #expect(store.handleKey("]"))
        #expect(store.brushSize > 0.06)
        #expect(store.handleKey("["))
        #expect(abs(store.brushSize - 0.06) < 1e-9)
        for _ in 0 ..< 60 { _ = store.handleKey("]") }
        #expect(store.brushSize <= 0.5, "the brush has a maximum size")
        for _ in 0 ..< 120 { _ = store.handleKey("[") }
        #expect(store.brushSize >= 0.005, "and a minimum")

        #expect(!store.showMaskOverlay)
        #expect(store.handleKey("o"))
        #expect(store.showMaskOverlay)

        #expect(store.handleKey("\u{1B}"))
        #expect(store.maskTool == .none)
        #expect(!store.handleKey("\u{1B}"), "nothing left to close, so Escape passes through")
    }

    @Test func maskKeysDoNothingWhenNoMaskToolIsOpen() {
        let (store, _) = makeStore()
        store.workspace = .photo
        #expect(!store.handleKey("o"))
        #expect(!store.handleKey("["))
        store.workspace = .cull
        store.chooseMaskTool(.brush)
        store.workspace = .cull
        #expect(!store.handleKey("]"))
    }

    @Test func maskEditingEndsWhenThePhotoOrWorkspaceChanges() throws {
        let (store, photos) = makeStore()
        store.workspace = .photo
        store.addMask(.linear(start: point(0, 0), end: point(0, 1)))
        #expect(store.isMaskEditing)

        store.select(store.allPhotos[1])
        #expect(!store.isMaskEditing)
        #expect(store.selectedMaskID == nil)

        store.addMask(.linear(start: point(0, 0), end: point(0, 1)))
        store.workspace = .library
        #expect(!store.isMaskEditing)
        _ = photos
    }

    @Test func maskEditingClosesZoomAndCrop() throws {
        let (store, _) = makeStore()
        store.workspace = .photo
        store.setFocusViewport(pixels: CGSize(width: 300, height: 200))
        store.enterZoom100()
        #expect(store.isZoom100)

        store.chooseMaskTool(.radial)
        #expect(!store.isZoom100)
        #expect(store.previewMode == .edited)
    }

    // MARK: Geometry

    @Test func theStoreMapsUsingThePhotosSizeAndEdits() throws {
        let (store, _) = makeStore()
        #expect(store.currentGeometry?.finishedSize == CGSize(width: 6000, height: 4000))
        store.updateAdjustments { $0.rotationQuarterTurns = 1 }
        let size = try #require(store.currentGeometry?.finishedSize)
        #expect(abs(size.width - 4000) < 1e-6 && abs(size.height - 6000) < 1e-6)

        let (unknown, _) = makeStore(withSize: false)
        #expect(unknown.currentGeometry == nil)
    }

    @Test func fittedFrameMatchesTheWayThePreviewIsLaidOut() throws {
        let view = CGSize(width: 900, height: 700), image = CGSize(width: 1800, height: 1200)
        let frame = MaskEditingLayer.fittedFrame(in: view, image: image)

        #expect(abs(frame.midX - view.width / 2) < 1e-6 && abs(frame.midY - view.height / 2) < 1e-6)
        #expect(abs(frame.width / frame.height - 1.5) < 1e-6)
        // The same rectangle the click-to-zoom mapping uses: its corners are 0 and 1.
        let topLeft = try #require(PhotoComparisonView.normalizedPoint(CGPoint(x: frame.minX + 0.5, y: frame.minY + 0.5), in: view, image: image))
        #expect(topLeft.x < 0.01 && topLeft.y < 0.01)
        #expect(PhotoComparisonView.normalizedPoint(CGPoint(x: frame.minX - 2, y: frame.midY), in: view, image: image) == nil)
    }

    // MARK: Copy and sync

    @Test func syncingCarriesGradientsToTheSelectionButNotBrushes() throws {
        let (store, _) = makeStore(photos: 3)
        let photos = store.allPhotos
        store.select(photos[0])
        store.addMask(.linear(start: point(0.5, 0), end: point(0.5, 0.4)))
        store.chooseMaskTool(.brush)
        store.beginBrushStroke(at: point(0.5, 0.5), erasing: false)
        store.endBrushStroke()
        store.chooseMaskTool(.none)
        store.extendSelection(to: photos[2])

        store.syncSettings(groups: [.masks])

        for other in photos[1...] {
            let masks = try #require(store.project.adjustmentsByAssetID[other.id]).masks
            #expect(masks.count == 1 && masks[0].shape.isGradient)
        }
        #expect(store.project.adjustmentsByAssetID[photos[0].id]?.masks.count == 2, "the source keeps both")
    }
}

struct MaskOverlayRenderingTests {
    private func makePhoto(_ temp: TempDirectory) throws -> URL {
        try writeTestJPEG(to: temp.url.appendingPathComponent("p.jpg"), width: 800, height: 600)
    }

    private func topMask() -> LocalMask {
        var mask = LocalMask(shape: .linear(start: NormalizedPoint(x: 0.5, y: 0.1), end: NormalizedPoint(x: 0.5, y: 0.5)))
        mask.adjustments.exposure = -1.5
        return mask
    }

    private func alpha(of image: CGImage, x: Int, y: Int) -> Int {
        var data = [UInt8](repeating: 0, count: 4)
        data.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        }
        return Int(data[3])
    }

    @Test func theOverlayIsOnlyMadeWhenAskedForAndMatchesThePreview() async throws {
        let temp = try TempDirectory()
        let url = try makePhoto(temp)
        var adjustments = PhotoAdjustments()
        let mask = topMask()
        adjustments.masks = [mask]
        let renderer = PhotoRenderer()

        let without = try #require(await renderer.preview(url: url, adjustments: adjustments))
        #expect(without.maskOverlay == nil)

        let with = try #require(await renderer.preview(url: url, adjustments: adjustments, overlayMaskID: mask.id))
        let overlay = try #require(with.maskOverlay).cgImage
        #expect(overlay.width == with.edited.cgImage.width && overlay.height == with.edited.cgImage.height)

        #expect(alpha(of: overlay, x: overlay.width / 2, y: 10) > 230, "strong where the mask applies fully")
        #expect(alpha(of: overlay, x: overlay.width / 2, y: overlay.height - 10) < 15, "clear where it does not")

        let unknown = try #require(await renderer.preview(url: url, adjustments: adjustments, overlayMaskID: UUID()))
        #expect(unknown.maskOverlay == nil)
    }

    @Test func theOverlayFollowsARotatedPhoto() async throws {
        let temp = try TempDirectory()
        let url = try makePhoto(temp)
        var adjustments = PhotoAdjustments()
        let mask = topMask()
        adjustments.masks = [mask]
        adjustments.rotationQuarterTurns = 1
        let renderer = PhotoRenderer()

        let result = try #require(await renderer.preview(url: url, adjustments: adjustments, overlayMaskID: mask.id))
        let overlay = try #require(result.maskOverlay).cgImage

        // The original's top edge is now a side edge; the middle of the frame is unmasked.
        let left = alpha(of: overlay, x: 5, y: overlay.height / 2)
        let right = alpha(of: overlay, x: overlay.width - 5, y: overlay.height / 2)
        #expect(max(left, right) > 200 && min(left, right) < 15)
        #expect(alpha(of: overlay, x: overlay.width / 2, y: overlay.height / 2) < 30)
        #expect(overlay.height > overlay.width, "the picture is now portrait")
    }

    @Test func aMaskedAdjustmentReachesThePreviewAndTheExport() async throws {
        let temp = try TempDirectory()
        let url = try makePhoto(temp)
        var adjustments = PhotoAdjustments()
        adjustments.masks = [topMask()]
        let renderer = PhotoRenderer()

        let plain = try #require(await renderer.preview(url: url, adjustments: PhotoAdjustments())).edited.cgImage
        let masked = try #require(await renderer.preview(url: url, adjustments: adjustments)).edited.cgImage
        #expect(pixel(of: masked, x: 400, y: 10).r < pixel(of: plain, x: 400, y: 10).r - 30, "darker where masked")
        #expect(abs(pixel(of: masked, x: 400, y: 590).r - pixel(of: plain, x: 400, y: 590).r) <= 2, "unchanged elsewhere")

        let output = temp.url.appendingPathComponent("out.jpg")
        try await PhotoRenderer(workingCacheLimit: 0).export(url: url, adjustments: adjustments, to: output, type: .jpeg)
        let exported = try #require(loadCGImage(output))
        let unmasked = temp.url.appendingPathComponent("plain.jpg")
        try await PhotoRenderer(workingCacheLimit: 0).export(url: url, adjustments: PhotoAdjustments(), to: unmasked, type: .jpeg)
        let exportedPlain = try #require(loadCGImage(unmasked))
        #expect(pixel(of: exported, x: 400, y: 10).r < pixel(of: exportedPlain, x: 400, y: 10).r - 30)
    }

    private func loadCGImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
