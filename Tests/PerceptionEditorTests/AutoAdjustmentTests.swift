import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PerceptionEditor

private func autoGradient(_ low: Double, _ high: Double) throws -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = try #require(CGContext(data: nil, width: 128, height: 96, bitsPerComponent: 8,
        bytesPerRow: 512, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let gradient = try #require(CGGradient(colorsSpace: space,
        colors: [srgbColor(low, low, low), srgbColor(high, high, high)] as CFArray, locations: nil))
    context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 128, y: 0), options: [])
    return try #require(context.makeImage())
}

private func autoPhoto(_ temp: TempDirectory, low: Double = 0.05, high: Double = 0.3) throws -> URL {
    let url = temp.url.appendingPathComponent("photo.jpg")
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try autoGradient(low, high), nil)
    #expect(CGImageDestinationFinalize(destination))
    return url
}

private func averageBrightness(_ image: CGImage) throws -> Double {
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    try pixels.withUnsafeMutableBytes { buffer in
        let context = try #require(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return stride(from: 0, to: pixels.count, by: 4).reduce(0.0) { $0 + Double(pixels[$1]) }
        / Double(image.width * image.height * 255)
}

struct AutoToneTests {
    @Test func darkAndBrightPhotosReceiveOppositeExposureCorrections() throws {
        let dark = try #require(PhotoAutoTone.analyze(autoGradient(0.05, 0.3)))
        let bright = try #require(PhotoAutoTone.analyze(autoGradient(0.75, 0.99)))
        #expect(dark.exposure > 0 && bright.exposure < 0)
        for result in [dark, bright] {
            #expect((-1.5...1.5).contains(result.exposure))
            #expect((-1...1).contains(result.contrast))
            #expect((-1...0).contains(result.highlights))
            #expect((0...1).contains(result.shadows))
        }
    }

    @Test func completelyClippedAndTransparentImagesDoNotInventCorrections() throws {
        #expect(try PhotoAutoTone.analyze(autoGradient(0, 0)) == .neutral)
        #expect(try PhotoAutoTone.analyze(autoGradient(1, 1)) == .neutral)
        let transparent = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
            bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        #expect(PhotoAutoTone.analyze(transparent) == nil)
    }

    @Test func rendererAutoActuallyBrightensDarkPhotosAndReducesOverexposure() async throws {
        for (low, high, brighten) in [(0.05, 0.3, true), (0.75, 0.99, false)] {
            let temp = try TempDirectory()
            let url = try autoPhoto(temp, low: low, high: high)
            let renderer = PhotoRenderer()
            let before = try #require(await renderer.preview(url: url, adjustments: .neutral)).edited.cgImage
            let auto = try #require(await renderer.autoTone(url: url, adjustments: .neutral))
            let after = try #require(await renderer.preview(url: url, adjustments: auto.applying(to: .neutral))).edited.cgImage
            let oldMean = try averageBrightness(before)
            let newMean = try averageBrightness(after)
            #expect(brighten ? newMean > oldMean + 0.08 : newMean < oldMean - 0.08,
                    "range=\(low)...\(high), before=\(oldMean), after=\(newMean), auto=\(auto)")
            // Auto meters with the Light controls reset, so repeated clicks do not drift.
            let again = await renderer.autoTone(url: url, adjustments: auto.applying(to: .neutral))
            #expect(again == auto)
        }
    }

    @Test(.enabled(if: RawSample.isAvailable))
    func autoCanAnalyzeARealRawWithTheCurrentWhiteBalance() async throws {
        var current = PhotoAdjustments.neutral
        current.raw.temperature = 5200
        current.exposure = 2
        let rawURL = try #require(RawSample.url)
        let auto = try #require(await PhotoRenderer().autoTone(url: rawURL, adjustments: current))
        let applied = auto.applying(to: current)
        #expect(applied.raw == current.raw)
        #expect(applied.exposure.isFinite && applied.shadows.isFinite)
    }
}

private actor AutoAnalysisGate {
    private var continuation: CheckedContinuation<AutoToneAdjustments?, Never>?
    private(set) var started = false
    func analyze() async -> AutoToneAdjustments? {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish() {
        continuation?.resume(returning: AutoToneAdjustments(exposure: 1, contrast: 0.1, highlights: -0.2, shadows: 0.2))
        continuation = nil
    }
}

@MainActor
struct AutoAdjustmentStoreTests {
    private func makeStore(_ url: URL, analyzer: (@Sendable (URL, PhotoAdjustments) async -> AutoToneAdjustments?)? = nil) -> (EditorStore, MediaAsset) {
        let store = EditorStore(autoToneAnalyzer: analyzer)
        let asset = MediaAsset(url: url)
        store.project.media = [asset]
        store.project.adjustmentsByAssetID[asset.id] = .neutral
        store.selectedAssetID = asset.id
        store.selectedAssetIDs = [asset.id]
        return (store, asset)
    }
    private func waitFor(_ gate: AutoAnalysisGate) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !(await gate.started), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(await gate.started)
    }

    @Test func autoPreservesOtherEditsAndIsOneUndoableHistoryStep() async throws {
        let temp = try TempDirectory()
        let (store, asset) = makeStore(try autoPhoto(temp))
        var before = PhotoAdjustments(exposure: -0.5, temperature: 0.2, tint: -0.1, saturation: 0.1, sharpness: 0.2)
        before.cropRect = CropRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        before.raw.temperature = 5200
        before.masks = [LocalMask(name: "Keep mask", shape: .linear(start: NormalizedPoint(x: 0, y: 0), end: NormalizedPoint(x: 1, y: 1)))]
        store.project.adjustmentsByAssetID[asset.id] = before
        let untouched = MediaAsset(url: asset.url)
        store.project.media.append(untouched)
        store.project.adjustmentsByAssetID[untouched.id] = .neutral
        store.selectedAssetIDs.insert(untouched.id)
        let task = try #require(store.autoAdjustPhoto())
        await task.value
        let after = store.selectedAdjustments
        #expect(after.exposure != before.exposure)
        #expect(AutoToneAdjustments.neutral.applying(to: after) == AutoToneAdjustments.neutral.applying(to: before))
        #expect(store.project.adjustmentsByAssetID[untouched.id] == .neutral)
        #expect(store.selectedHistory.map(\.name) == ["Start", "Auto Adjust"])
        store.undoPhotoEdit()
        #expect(store.selectedAdjustments == before && !store.canUndoPhotoEdit)
        store.redoPhotoEdit()
        #expect(store.selectedAdjustments == after)
        let repeatedAuto = try #require(store.autoAdjustPhoto())
        await repeatedAuto.value
        #expect(store.selectedHistory.count == 2, "Repeated Auto should not add redundant history")
    }

    @Test func lateAnalysisDoesNotOverwriteManualEdits() async throws {
        let temp = try TempDirectory()
        let gate = AutoAnalysisGate()
        let (store, _) = makeStore(try autoPhoto(temp), analyzer: { _, _ in await gate.analyze() })
        let task = try #require(store.autoAdjustPhoto())
        try await waitFor(gate)
        #expect(!store.canAutoAdjustPhoto)
        store.updateAdjustments { $0.exposure = 2.3 }
        await gate.finish()
        await task.value
        #expect(store.selectedAdjustments.exposure == 2.3 && !store.isAutoAdjusting)
        #expect(!store.selectedHistory.contains { $0.name == "Auto Adjust" })
    }

    @Test func changingProjectsOrSelectionDiscardsTheOldAnalysis() async throws {
        for replaceProject in [false, true] {
            let temp = try TempDirectory()
            let gate = AutoAnalysisGate()
            let (store, _) = makeStore(try autoPhoto(temp), analyzer: { _, _ in await gate.analyze() })
            let task = try #require(store.autoAdjustPhoto())
            try await waitFor(gate)
            if replaceProject { try store.loadProject(from: writeEmptyProject(temp)) }
            else { store.selectedAssetID = nil }
            let before = store.project
            await gate.finish()
            await task.value
            #expect(store.project == before && !store.isAutoAdjusting)
        }
    }

    private func writeEmptyProject(_ temp: TempDirectory) throws -> URL {
        let url = temp.url.appendingPathComponent("new.pmedit")
        try ProjectDocument().save(EditorProject(name: "New"), to: url)
        return url
    }

    @Test func emptyMissingAndVideoSelectionsCannotStartAuto() {
        let store = EditorStore()
        #expect(!store.canAutoAdjustPhoto && store.autoAdjustPhoto() == nil)
        let missing = MediaAsset(url: URL(fileURLWithPath: "/missing-photo.jpg"))
        store.project.media = [missing]
        store.selectedAssetID = missing.id
        #expect(!store.canAutoAdjustPhoto)
        store.project.media[0].kind = .video
        #expect(!store.canAutoAdjustPhoto)
    }
}
