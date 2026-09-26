import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import PerceptionEditor

struct RawSettingsTests {
    @Test func aPhotoWithNoRawEditsStoresNothingAndReadsBackAsDefault() throws {
        let settings = RawSettings()
        #expect(settings.isDefault)
        #expect(!settings.hasWhiteBalance)

        let decoded = try JSONDecoder().decode(RawSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
        #expect(try JSONEncoder().encode(settings) == Data("{}".utf8))
    }

    @Test func cacheKeysChangeWithEverySetting() {
        var keys: Set<String> = [RawSettings().cacheKey]
        var settings = RawSettings(); settings.temperature = 5000; keys.insert(settings.cacheKey)
        settings = RawSettings(); settings.tint = 10; keys.insert(settings.cacheKey)
        settings = RawSettings(); settings.luminanceNoiseReduction = 0.5; keys.insert(settings.cacheKey)
        settings = RawSettings(); settings.colorNoiseReduction = 0.5; keys.insert(settings.cacheKey)
        settings = RawSettings(); settings.sharpness = 0.5; keys.insert(settings.cacheKey)
        settings = RawSettings(); settings.detail = 1; keys.insert(settings.cacheKey)
        settings = RawSettings(); settings.lensCorrection = false; keys.insert(settings.cacheKey)
        settings = RawSettings(); settings.lensCorrection = true; keys.insert(settings.cacheKey)
        #expect(keys.count == 9)
    }

    @Test func projectsSavedBeforeRawSettingsExistedStillOpen() throws {
        let old = Data("""
        {"exposure": 0.4, "contrast": 0.1, "cropAspect": "3:2"}
        """.utf8)

        let decoded = try JSONDecoder().decode(PhotoAdjustments.self, from: old)

        #expect(decoded.exposure == 0.4)
        #expect(decoded.cropAspect == .photo)
        #expect(decoded.raw.isDefault)
        #expect(decoded.vignette == 0)
    }

    @Test func rawSettingsSurviveSaveAndOpen() throws {
        var adjustments = PhotoAdjustments(exposure: 0.2)
        adjustments.raw.temperature = 5200
        adjustments.raw.tint = -8
        adjustments.raw.luminanceNoiseReduction = 0.35
        adjustments.raw.lensCorrection = false
        let asset = MediaAsset(url: URL(fileURLWithPath: "/x/P1.RW2"))
        let project = EditorProject(name: "P", media: [asset], adjustmentsByAssetID: [asset.id: adjustments])

        let document = ProjectDocument()
        let decoded = try document.project(from: document.data(for: project))

        #expect(decoded.adjustmentsByAssetID[asset.id] == adjustments)
        #expect(decoded.schemaVersion == EditorProject.currentSchemaVersion)
    }

    @Test func aLookCarriesDetailButLeavesWhiteBalanceToEachPhoto() {
        var reference = PhotoAdjustments(exposure: 0.3)
        reference.raw.temperature = 3200
        reference.raw.tint = 12
        reference.raw.luminanceNoiseReduction = 0.6

        var target = PhotoAdjustments()
        target.raw.temperature = 6100

        let result = reference.look(keepingGeometryOf: target)

        #expect(result.exposure == 0.3)
        #expect(result.raw.luminanceNoiseReduction == 0.6)
        #expect(result.raw.temperature == 6100)
        #expect(result.raw.tint == nil)
        #expect(reference.lookOnly.raw.temperature == nil)
        #expect(reference.lookOnly.raw.luminanceNoiseReduction == 0.6)
    }

    @Test func whiteBalancePresetsAreOrderedFromCoolToWarmLight() {
        #expect(WhiteBalancePreset.tungsten.temperature < WhiteBalancePreset.fluorescent.temperature)
        #expect(WhiteBalancePreset.fluorescent.temperature < WhiteBalancePreset.daylight.temperature)
        #expect(WhiteBalancePreset.daylight.temperature < WhiteBalancePreset.cloudy.temperature)
        #expect(WhiteBalancePreset.cloudy.temperature < WhiteBalancePreset.shade.temperature)
    }
}

struct FocusRegionTests {
    private func makeRenderer() -> PhotoRenderer { PhotoRenderer(workingCacheLimit: 0) }

    @Test func positionsMapToTheRightPartOfThePhoto() async throws {
        let temp = try TempDirectory()
        let url = try writeQuadrantPNG(to: temp.url.appendingPathComponent("q.png"))
        let renderer = makeRenderer()
        let viewport = CGSize(width: 100, height: 60)

        func color(at center: CGPoint) async throws -> (r: Int, g: Int, b: Int) {
            let render = try #require(await renderer.focusRegion(
                url: url, adjustments: .neutral, center: center, viewportPixels: viewport
            ))
            return pixel(of: render.image.cgImage, x: 50, y: 30)
        }

        let topLeft = try await color(at: CGPoint(x: 0.1, y: 0.1))
        let topRight = try await color(at: CGPoint(x: 0.9, y: 0.1))
        let bottomLeft = try await color(at: CGPoint(x: 0.1, y: 0.9))
        let bottomRight = try await color(at: CGPoint(x: 0.9, y: 0.9))

        #expect(topLeft.r > 200 && topLeft.g < 60 && topLeft.b < 60)          // red
        #expect(topRight.g > 200 && topRight.r < 60 && topRight.b < 60)       // green
        #expect(bottomLeft.b > 200 && bottomLeft.r < 60 && bottomLeft.g < 60) // blue
        #expect(bottomRight.r > 200 && bottomRight.g > 200 && bottomRight.b < 60) // yellow
    }

    @Test func rendersAtOneToOneAndClampsAtTheEdges() async throws {
        let temp = try TempDirectory()
        let url = try writeQuadrantPNG(to: temp.url.appendingPathComponent("q.png"))
        let renderer = makeRenderer()

        let corner = try #require(await renderer.focusRegion(
            url: url, adjustments: .neutral, center: CGPoint(x: 0, y: 0), viewportPixels: CGSize(width: 200, height: 150)
        ))
        #expect(corner.image.cgImage.width == 200 && corner.image.cgImage.height == 150)
        #expect(corner.region == CGRect(x: 0, y: 0, width: 200, height: 150))
        #expect(corner.fullSize == CGSize(width: 800, height: 600))

        let far = try #require(await renderer.focusRegion(
            url: url, adjustments: .neutral, center: CGPoint(x: 1, y: 1), viewportPixels: CGSize(width: 200, height: 150)
        ))
        #expect(far.region == CGRect(x: 600, y: 450, width: 200, height: 150))
    }

    @Test func aViewportLargerThanThePhotoShowsTheWholePhoto() async throws {
        let temp = try TempDirectory()
        let url = try writeQuadrantPNG(to: temp.url.appendingPathComponent("q.png"), width: 300, height: 200)

        let render = try #require(await makeRenderer().focusRegion(
            url: url, adjustments: .neutral, center: CGPoint(x: 0.5, y: 0.5), viewportPixels: CGSize(width: 2000, height: 1500)
        ))

        #expect(render.image.cgImage.width == 300 && render.image.cgImage.height == 200)
        #expect(render.region == CGRect(x: 0, y: 0, width: 300, height: 200))
    }

    @Test func cropAndEditsApplyToTheFinishedPhoto() async throws {
        let temp = try TempDirectory()
        let url = try writeQuadrantPNG(to: temp.url.appendingPathComponent("q.png"))
        let renderer = makeRenderer()

        var square = PhotoAdjustments.neutral
        square.cropAspect = .square
        let cropped = try #require(await renderer.focusRegion(
            url: url, adjustments: square, center: CGPoint(x: 0.5, y: 0.5), viewportPixels: CGSize(width: 100, height: 100)
        ))
        #expect(cropped.fullSize == CGSize(width: 600, height: 600))

        // Desaturating turns the red quadrant gray.
        var gray = PhotoAdjustments.neutral
        gray.saturation = -1
        let render = try #require(await renderer.focusRegion(
            url: url, adjustments: gray, center: CGPoint(x: 0.1, y: 0.1), viewportPixels: CGSize(width: 100, height: 60)
        ))
        let p = pixel(of: render.image.cgImage, x: 50, y: 30)
        #expect(abs(p.r - p.g) < 12 && abs(p.g - p.b) < 12)
    }

    @Test func theFullResolutionBufferIsKeptForOnePhotoAndReleasable() async throws {
        let temp = try TempDirectory()
        let first = try writeQuadrantPNG(to: temp.url.appendingPathComponent("a.png"))
        let second = try writeQuadrantPNG(to: temp.url.appendingPathComponent("b.png"))
        let renderer = makeRenderer()
        let viewport = CGSize(width: 100, height: 100)

        #expect(await !renderer.hasFullResolution)
        _ = await renderer.focusRegion(url: first, adjustments: .neutral, center: .init(x: 0.5, y: 0.5), viewportPixels: viewport)
        #expect(await renderer.hasFullResolution)
        _ = await renderer.focusRegion(url: second, adjustments: .neutral, center: .init(x: 0.5, y: 0.5), viewportPixels: viewport)
        #expect(await renderer.hasFullResolution)

        await renderer.releaseFullResolution()
        #expect(await !renderer.hasFullResolution)
    }

    @Test func rawSettingsDoNotForceANewDecodeOfANonRawFile() async throws {
        let temp = try TempDirectory()
        let url = try writeTestJPEG(to: temp.url.appendingPathComponent("a.jpg"))
        let renderer = PhotoRenderer(workingCacheLimit: 4)

        var adjustments = PhotoAdjustments.neutral
        _ = await renderer.preview(url: url, adjustments: adjustments)
        adjustments.raw.temperature = 4000
        _ = await renderer.preview(url: url, adjustments: adjustments)
        adjustments.raw.tint = 30
        _ = await renderer.preview(url: url, adjustments: adjustments)

        #expect(await renderer.cachedWorkingSourceCount == 1)
        #expect(await renderer.rawInfo(url: url) == nil)
    }

    @Test func aWorkingCopyKeepsTheColorsOfTheFile() async throws {
        let temp = try TempDirectory()
        let url = try writeQuadrantPNG(to: temp.url.appendingPathComponent("q.png"))

        let result = try #require(await PhotoRenderer().preview(url: url, adjustments: .neutral))
        let red = pixel(of: result.edited.cgImage, x: 50, y: 50)
        let yellow = pixel(of: result.edited.cgImage, x: result.edited.cgImage.width - 50, y: result.edited.cgImage.height - 50)

        #expect(red.r > 245 && red.g < 12 && red.b < 12)
        #expect(yellow.r > 245 && yellow.g > 245 && yellow.b < 12)
    }
}

struct FocusGeometryTests {
    @Test func clicksMapToPositionsOnTheFittedPhoto() throws {
        // A 200×100 photo in a 456×256 view, with 28 pt of padding: it fits at 2× and is centered.
        let view = CGSize(width: 456, height: 256)
        let image = CGSize(width: 200, height: 100)

        let center = try #require(PhotoComparisonView.normalizedPoint(CGPoint(x: 228, y: 128), in: view, image: image))
        #expect(abs(center.x - 0.5) < 0.001 && abs(center.y - 0.5) < 0.001)

        let topLeft = try #require(PhotoComparisonView.normalizedPoint(CGPoint(x: 28.5, y: 28.5), in: view, image: image))
        #expect(topLeft.x < 0.01 && topLeft.y < 0.01)

        // In the padding, outside the photo.
        #expect(PhotoComparisonView.normalizedPoint(CGPoint(x: 5, y: 5), in: view, image: image) == nil)
        #expect(PhotoComparisonView.normalizedPoint(CGPoint(x: 228, y: 250), in: view, image: image) == nil)
    }
}

@MainActor
struct ZoomStoreTests {
    private func makeStore(_ temp: TempDirectory) throws -> (EditorStore, MediaAsset) {
        let url = try writeQuadrantPNG(to: temp.url.appendingPathComponent("q.png"))
        let asset = MediaAsset(url: url, pixelWidth: 800, pixelHeight: 600)
        let store = EditorStore()
        store.project.media = [asset]
        store.project.adjustmentsByAssetID[asset.id] = .neutral
        store.workspace = .cull
        store.select(asset)
        return (store, asset)
    }

    @Test func zoomingInShowsAPixelPerfectRegionAndPanningMovesIt() async throws {
        let temp = try TempDirectory()
        let (store, _) = try makeStore(temp)
        store.setFocusViewport(pixels: CGSize(width: 300, height: 200))

        store.enterZoom100(at: CGPoint(x: 0.5, y: 0.5))
        #expect(store.isZoom100)
        try await waitUntil { store.focusImage != nil }
        #expect(store.focusImage?.width == 300 && store.focusImage?.height == 200)
        #expect(abs(store.zoomCenter.x - 0.5) < 0.01)

        // Dragging the photo 100 px to the right moves the view 100 px left.
        store.panZoom(from: CGPoint(x: 0.5, y: 0.5), translation: CGSize(width: 100, height: 0))
        try await waitUntil { abs(store.zoomCenter.x - (0.5 - 100.0 / 800.0)) < 0.01 && !store.isLoadingFocus }
        #expect(abs(store.zoomCenter.x - 0.375) < 0.01)

        store.exitZoom100()
        #expect(!store.isZoom100)
        #expect(store.focusImage == nil)
    }

    @Test func panningNeverLeavesThePhoto() async throws {
        let temp = try TempDirectory()
        let (store, _) = try makeStore(temp)
        store.setFocusViewport(pixels: CGSize(width: 300, height: 200))
        store.enterZoom100()
        try await waitUntil { store.focusImage != nil }

        store.panZoom(from: CGPoint(x: 0.5, y: 0.5), translation: CGSize(width: -50_000, height: -50_000))
        try await waitUntil { !store.isLoadingFocus && store.zoomCenter.x > 0.5 }

        // The view stops at the bottom-right corner: its center is half a viewport in from each edge.
        #expect(abs(store.zoomCenter.x - (800 - 150) / 800) < 0.01)
        #expect(abs(store.zoomCenter.y - (600 - 100) / 600) < 0.01)
    }

    @Test func zoomIsRefusedWhileComparingAndClosesWhenComparisonStarts() async throws {
        let temp = try TempDirectory()
        let (store, _) = try makeStore(temp)
        store.setFocusViewport(pixels: CGSize(width: 300, height: 200))

        store.toggleCompare()
        store.enterZoom100()
        #expect(!store.isZoom100)

        store.toggleCompare()
        store.enterZoom100()
        #expect(store.isZoom100)
        store.toggleCompare()
        #expect(!store.isZoom100)
    }

    @Test func zoomFollowsThePhotoWhenNavigatingInTheCullView() async throws {
        let temp = try TempDirectory()
        let first = try writeQuadrantPNG(to: temp.url.appendingPathComponent("a.png"))
        let second = try writeTestJPEG(to: temp.url.appendingPathComponent("b.jpg"), width: 800, height: 600)
        let a = MediaAsset(url: first, captureDate: Date(timeIntervalSince1970: 1_000))
        let b = MediaAsset(url: second, captureDate: Date(timeIntervalSince1970: 2_000))
        let store = EditorStore()
        store.project.media = [a, b]
        store.workspace = .cull
        store.select(a)
        store.setFocusViewport(pixels: CGSize(width: 200, height: 150))
        store.enterZoom100()
        try await waitUntil { store.focusImage != nil && !store.isLoadingFocus }
        let firstImage = store.focusImage

        store.perform(.next)
        #expect(store.selectedAssetID == b.id)
        try await waitUntil { store.focusImage != nil && store.focusImage !== firstImage && !store.isLoadingFocus }

        #expect(store.isZoom100)
    }

    @Test func leavingTheDevelopAndCullViewsClosesTheZoom() async throws {
        let temp = try TempDirectory()
        let (store, _) = try makeStore(temp)
        store.setFocusViewport(pixels: CGSize(width: 300, height: 200))
        store.enterZoom100()
        #expect(store.isZoom100)

        store.workspace = .library
        #expect(!store.isZoom100)
    }

    @Test func zKeyTogglesAndEscapeLeaves() async throws {
        let temp = try TempDirectory()
        let (store, _) = try makeStore(temp)
        store.setFocusViewport(pixels: CGSize(width: 300, height: 200))

        #expect(store.handleKey("z"))
        #expect(store.isZoom100)
        #expect(store.handleKey("\u{1B}"))
        #expect(!store.isZoom100)
        // Escape does nothing when there is nothing to leave, so other views can use it.
        #expect(!store.handleKey("\u{1B}"))

        store.workspace = .library
        #expect(!store.handleKey("z"))
    }
}

struct RealRawTests {
    @Test(.enabled(if: RawSample.isAvailable))
    func theEngineReportsTheCamerasWhiteBalanceAndDefaults() async throws {
        let url = try #require(RawSample.url)

        let info = try #require(await PhotoRenderer().rawInfo(url: url))

        #expect((2000 ... 12000).contains(info.asShotTemperature))
        #expect((-150 ... 150).contains(info.asShotTint))
        #expect(info.supportsNoiseReduction && info.supportsLensCorrection)
        #expect((0 ... 1).contains(info.defaultLuminanceNoiseReduction))
    }

    @Test(.enabled(if: RawSample.isAvailable))
    func higherKelvinRendersWarmer() async throws {
        let url = try #require(RawSample.url)
        let renderer = PhotoRenderer()

        func redToBlue(_ temperature: Double) async throws -> Double {
            var adjustments = PhotoAdjustments.neutral
            adjustments.raw.temperature = temperature
            let image = try #require(await renderer.preview(url: url, adjustments: adjustments)).edited.cgImage
            var red = 0.0, blue = 0.0
            for y in stride(from: 0, to: image.height, by: 40) {
                for x in stride(from: 0, to: image.width, by: 40) {
                    let p = pixel(of: image, x: x, y: y)
                    red += Double(p.r); blue += Double(p.b)
                }
            }
            return red / max(1, blue)
        }

        let cool = try await redToBlue(3000)
        let warm = try await redToBlue(8000)
        #expect(warm > cool * 1.4)
    }

    @Test(.enabled(if: RawSample.isAvailable))
    func aWhiteBalanceDragKeepsOneEditedDecodePerPhoto() async throws {
        let url = try #require(RawSample.url)
        let renderer = PhotoRenderer(workingCacheLimit: 4)

        for kelvin in [3500.0, 4200, 5000, 5800] {
            var adjustments = PhotoAdjustments.neutral
            adjustments.raw.temperature = kelvin
            _ = await renderer.preview(url: url, adjustments: adjustments)
        }
        _ = await renderer.original(url: url)

        // The untouched decode plus the latest edited one.
        #expect(await renderer.cachedWorkingSourceCount == 2)
    }

    @Test(.enabled(if: RawSample.isAvailable))
    func exportsUseTheRawSettings() async throws {
        let url = try #require(RawSample.url)
        let temp = try TempDirectory()

        func exportedRedToBlue(_ temperature: Double) async throws -> Double {
            var adjustments = PhotoAdjustments.neutral
            adjustments.raw.temperature = temperature
            let output = temp.url.appendingPathComponent("wb-\(Int(temperature)).jpg")
            try await PhotoRenderer(workingCacheLimit: 0).export(url: url, adjustments: adjustments, to: output, type: .jpeg)
            let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
            let image = try #require(CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 300
            ] as CFDictionary))
            var red = 0.0, blue = 0.0
            for y in stride(from: 0, to: image.height, by: 10) {
                for x in stride(from: 0, to: image.width, by: 10) {
                    let p = pixel(of: image, x: x, y: y)
                    red += Double(p.r); blue += Double(p.b)
                }
            }
            return red / max(1, blue)
        }

        let cool = try await exportedRedToBlue(3000)
        let warm = try await exportedRedToBlue(8000)
        #expect(warm > cool * 1.4)
    }

    @Test(.enabled(if: RawSample.isAvailable))
    func aFullResolutionViewOfARawFileIsPixelPerfect() async throws {
        let url = try #require(RawSample.url)
        let renderer = PhotoRenderer(workingCacheLimit: 0)

        let render = try #require(await renderer.focusRegion(
            url: url, adjustments: .neutral, center: CGPoint(x: 0.5, y: 0.5), viewportPixels: CGSize(width: 1200, height: 800)
        ))

        #expect(render.fullSize.width >= 5000)
        #expect(render.image.cgImage.width == 1200 && render.image.cgImage.height == 800)
    }
}
