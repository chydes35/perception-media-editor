import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PerceptionEditor

private enum ExportFixture {
    /// A 400 × 300 JPEG with camera EXIF, a GPS location and a body serial number.
    static func source(in folder: URL, gps: Bool = true) throws -> URL {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try #require(CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for band in 0 ..< 10 {
            context.setFillColor(CGColor(red: Double(band) / 10, green: 0.45, blue: 0.3, alpha: 1))
            context.fill(CGRect(x: band * 40, y: 0, width: 40, height: 300))
        }
        let url = folder.appendingPathComponent("source.jpg")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifISOSpeedRatings: [400], kCGImagePropertyExifFNumber: 2.8,
                kCGImagePropertyExifDateTimeOriginal: "2026:10:18 13:04:48",
                kCGImagePropertyExifBodySerialNumber: "SN-123456", kCGImagePropertyExifCameraOwnerName: "Owner",
            ],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Panasonic", kCGImagePropertyTIFFModel: "DC-S5"],
        ]
        if gps {
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 43.0, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 89.0, kCGImagePropertyGPSLongitudeRef: "W",
            ]
        }
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    static func properties(_ url: URL) -> [String: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return [:] }
        return properties
    }

    static func exif(_ url: URL) -> [String: Any] { properties(url)[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:] }
    static func tiff(_ url: URL) -> [String: Any] { properties(url)[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:] }
    static func iptc(_ url: URL) -> [String: Any] { properties(url)[kCGImagePropertyIPTCDictionary as String] as? [String: Any] ?? [:] }
    static func gps(_ url: URL) -> [String: Any]? { properties(url)[kCGImagePropertyGPSDictionary as String] as? [String: Any] }

    static func export(_ source: URL, to destination: URL, recipe: BatchExportRecipe,
                       adjustments: PhotoAdjustments = .neutral) async throws {
        try await PhotoRenderer(workingCacheLimit: 0, memoryTargetMB: 128)
            .export(url: source, adjustments: adjustments, to: destination, recipe: recipe)
    }
}

struct ExportRecipeEngineTests {
    @Test(arguments: ExportFormat.allCases)
    func everyFormatWritesADecodableFileOfTheRightSizeAndDepth(format: ExportFormat) async throws {
        let folder = try TempDirectory()
        let source = try ExportFixture.source(in: folder.url)
        let output = folder.url.appendingPathComponent("out.\(format.fileExtension)")
        try await ExportFixture.export(source, to: output, recipe: BatchExportRecipe(longEdgePixels: 200, format: format))

        let properties = ExportFixture.properties(output)
        #expect(properties[kCGImagePropertyPixelWidth as String] as? Int == 200)
        #expect(properties[kCGImagePropertyPixelHeight as String] as? Int == 150)
        let profile = properties[kCGImagePropertyProfileName as String] as? String ?? ""
        #expect(profile.contains("sRGB"), "\(format) carries an sRGB profile, not \(profile)")
        let depth = properties[kCGImagePropertyDepth as String] as? Int ?? 0
        switch format {
        case .jpeg: #expect(depth == 8)
        case .tiff16, .png16: #expect(depth == 16, "\(format) is \(depth)-bit")
        case .heic10: #expect(depth == 10, "HEIC is \(depth)-bit")
        }
        let image = CGImageSourceCreateWithURL(output as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        #expect(image != nil, "the file decodes")
    }

    @Test func cameraDataSurvivesAndPrivateDataIsRemovedByDefault() async throws {
        let folder = try TempDirectory()
        let source = try ExportFixture.source(in: folder.url)
        let output = folder.url.appendingPathComponent("out.jpg")
        try await ExportFixture.export(source, to: output, recipe: BatchExportRecipe())

        let exif = ExportFixture.exif(output)
        #expect(exif[kCGImagePropertyExifFNumber as String] as? Double == 2.8)
        #expect((exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int]) == [400])
        #expect(exif[kCGImagePropertyExifDateTimeOriginal as String] as? String == "2026:10:18 13:04:48")
        #expect(ExportFixture.tiff(output)[kCGImagePropertyTIFFModel as String] as? String == "DC-S5")
        #expect(ExportFixture.gps(output) == nil, "location is removed")
        #expect(exif[kCGImagePropertyExifBodySerialNumber as String] == nil, "serial number is removed")
        #expect(exif[kCGImagePropertyExifCameraOwnerName as String] == nil, "owner name is removed")
    }

    @Test func keepingPrivateDataKeepsTheLocation() async throws {
        let folder = try TempDirectory()
        let source = try ExportFixture.source(in: folder.url)
        let output = folder.url.appendingPathComponent("out.jpg")
        var recipe = BatchExportRecipe()
        recipe.metadata.removePrivateData = false
        try await ExportFixture.export(source, to: output, recipe: recipe)
        #expect(ExportFixture.gps(output)?[kCGImagePropertyGPSLatitude as String] as? Double == 43.0)
    }

    @Test func dimensionsAreTheExportsOwnNotTheSources() async throws {
        let folder = try TempDirectory()
        let source = try ExportFixture.source(in: folder.url)
        let output = folder.url.appendingPathComponent("out.jpg")
        try await ExportFixture.export(source, to: output, recipe: BatchExportRecipe(longEdgePixels: 200))
        let exif = ExportFixture.exif(output)
        #expect(exif[kCGImagePropertyExifPixelXDimension as String] as? Int == 200)
        #expect(exif[kCGImagePropertyExifPixelYDimension as String] as? Int == 150)
        #expect(ExportFixture.properties(output)[kCGImagePropertyOrientation as String] as? Int ?? 1 == 1)
    }

    @Test func copyrightAndCreatorAreWrittenToTIFFAndIPTC() async throws {
        let folder = try TempDirectory()
        let source = try ExportFixture.source(in: folder.url)
        let output = folder.url.appendingPathComponent("out.jpg")
        var recipe = BatchExportRecipe()
        recipe.metadata.copyright = "© 2026 Perception Media"
        recipe.metadata.creator = "Collin Heidemann"
        try await ExportFixture.export(source, to: output, recipe: recipe)

        let tiff = ExportFixture.tiff(output), iptc = ExportFixture.iptc(output)
        #expect(tiff[kCGImagePropertyTIFFCopyright as String] as? String == "© 2026 Perception Media")
        #expect(tiff[kCGImagePropertyTIFFArtist as String] as? String == "Collin Heidemann")
        #expect(iptc[kCGImagePropertyIPTCCopyrightNotice as String] as? String == "© 2026 Perception Media")
        #expect((iptc[kCGImagePropertyIPTCByline as String] as? [String]) == ["Collin Heidemann"])
    }

    @Test func noCopyrightSettingLeavesNoCopyrightFields() async throws {
        let folder = try TempDirectory()
        let source = try ExportFixture.source(in: folder.url)
        let output = folder.url.appendingPathComponent("out.jpg")
        try await ExportFixture.export(source, to: output, recipe: BatchExportRecipe())
        #expect(ExportFixture.tiff(output)[kCGImagePropertyTIFFCopyright as String] == nil)
        #expect(ExportFixture.iptc(output)[kCGImagePropertyIPTCCopyrightNotice as String] == nil)
    }

    @Test func metadataIsNeverWrittenBackToTheOriginal() async throws {
        let folder = try TempDirectory()
        let source = try ExportFixture.source(in: folder.url)
        let before = try Data(contentsOf: source)
        var recipe = BatchExportRecipe()
        recipe.metadata.copyright = "© Someone"
        try await ExportFixture.export(source, to: folder.url.appendingPathComponent("out.tif"),
                                       recipe: BatchExportRecipe(format: .tiff16, metadata: recipe.metadata))
        #expect(try Data(contentsOf: source) == before)
    }
}

struct OutputSharpeningTests {
    private func stepEdge(width: Int, height: Int = 32) -> CIImage {
        IQFixtures.image(width: width, height: height) { x, _ in
            let v: Float = x < width / 2 ? 0.1 : 0.5
            return (v, v, v)
        }
    }

    /// Largest overshoot past the bright side of the edge, in linear light.
    private func overshoot(_ image: CIImage) -> Double {
        let buffer = IQRender.pixels(of: image)
        let width = Int(image.extent.width)
        var peak = 0.0
        for x in 0 ..< width {
            peak = max(peak, IQRender.luma(IQRender.linear(buffer, width: width, x: x, y: 16)))
        }
        return peak
    }

    @Test func flatAreasDoNotMove() {
        let flat = IQFixtures.image(width: 64, height: 64) { _, _ in (0.3, 0.3, 0.3) }
        let before = IQRender.pixels(of: flat)
        for level in OutputSharpening.allCases {
            let after = IQRender.pixels(of: level.apply(to: flat))
            // Core Image's luminance sharpen leaves a sub-quantization offset (about a quarter of one
            // 8-bit step at the highest level); the bound is half a step of an 8-bit export.
            #expect(IQMetrics.compare(before, after).maxCodeDifference <= 128, "\(level) moved a flat area")
        }
    }

    @Test func sharpeningGrowsEdgeContrastInLevels() {
        let edge = stepEdge(width: 256)
        let none = overshoot(OutputSharpening.none.apply(to: edge))
        let low = overshoot(OutputSharpening.low.apply(to: edge))
        let standard = overshoot(OutputSharpening.standard.apply(to: edge))
        let high = overshoot(OutputSharpening.high.apply(to: edge))
        #expect(low > none + 0.005)
        #expect(standard > low)
        #expect(high > standard)
    }

    @Test func theRadiusFollowsTheLongEdge() {
        let small = OutputSharpening.radius(forLongEdge: 2048), large = OutputSharpening.radius(forLongEdge: 6000)
        #expect(abs(large / small - 6000.0 / 2048.0) < 0.01)
        #expect(OutputSharpening.radius(forLongEdge: 100) == 0.5, "never below half a pixel")
    }
}

struct ExportRecipeModelTests {
    @Test func theDefaultRecipeReproducesTheOriginalDelivery() {
        let recipe = BatchExportRecipe()
        #expect(recipe.format == .jpeg && recipe.sharpening == .none && recipe.jpegQuality == 0.92)
        #expect(recipe.longEdgePixels == nil && recipe.filenameSuffix == "_edited")
        #expect(recipe.metadata.removePrivateData, "privacy is on unless the photographer turns it off")
    }

    @Test func recipesRoundTripAndOldOnesDecodeWithDefaults() throws {
        var recipe = BatchExportRecipe(jpegQuality: 0.8, longEdgePixels: 2048, filenameSuffix: "_web",
                                       format: .heic10, sharpening: .high)
        recipe.metadata = ExportMetadataOptions(copyright: "© C", creator: "C", removePrivateData: false)
        let decoded = try JSONDecoder().decode(BatchExportRecipe.self, from: JSONEncoder().encode(recipe))
        #expect(decoded == recipe)

        let old = try JSONDecoder().decode(BatchExportRecipe.self, from: Data(#"{ "jpegQuality": 0.7 }"#.utf8))
        #expect(old.jpegQuality == 0.7 && old.format == .jpeg && old.sharpening == .none && old.metadata.removePrivateData)
    }

    @Test func metadataTextIsValidated() {
        #expect(throws: BatchExportError.self) {
            try BatchExportRecipe(metadata: ExportMetadataOptions(copyright: "two\nlines")).validate()
        }
        #expect(throws: BatchExportError.self) {
            try BatchExportRecipe(metadata: ExportMetadataOptions(creator: String(repeating: "x", count: 101))).validate()
        }
        #expect(throws: Never.self) {
            try BatchExportRecipe(metadata: ExportMetadataOptions(copyright: "© 2026 Perception Media", creator: "Collin")).validate()
        }
    }

    @Test func formatsMapToExtensionsBothWays() {
        for format in ExportFormat.allCases {
            #expect(ExportFormat(fileExtension: format.fileExtension) == format)
        }
        #expect(ExportFormat(fileExtension: "JPEG") == .jpeg && ExportFormat(fileExtension: "tiff") == .tiff16)
        #expect(ExportFormat(fileExtension: "gif") == nil)
        #expect(ExportFormat.jpeg.usesQuality && ExportFormat.heic10.usesQuality)
        #expect(!ExportFormat.tiff16.usesQuality && !ExportFormat.png16.usesQuality)
    }

    @Test func thePlannerUsesTheFormatsExtensionAndStillAvoidsCollisions() throws {
        let folder = try TempDirectory()
        let item = BatchExportItem(id: UUID(), source: URL(fileURLWithPath: "/Volumes/Card/P1000.RW2"), adjustments: .neutral)
        var reserved = Set<String>()
        let first = try BatchExportPlanner.destination(
            for: item, in: folder.url, suffix: "_print", fileExtension: "tif", reserved: &reserved, protecting: [])
        let second = try BatchExportPlanner.destination(
            for: item, in: folder.url, suffix: "_print", fileExtension: "tif", reserved: &reserved, protecting: [])
        #expect(first.lastPathComponent == "P1000_print.tif")
        #expect(second.lastPathComponent == "P1000_print-2.tif")
    }
}

@MainActor
struct ExportRecipeLibraryTests {
    private func library() -> (ExportRecipeLibrary, UserDefaults) {
        let defaults = UserDefaults(suiteName: "pme-export-recipes-\(UUID())")!
        return (ExportRecipeLibrary(defaults: defaults), defaults)
    }

    @Test func startsOnTheOriginalDeliveryRecipe() {
        let (library, _) = library()
        #expect(library.selected.id == ExportRecipeLibrary.builtIns[0].id)
        #expect(library.selected.recipe == BatchExportRecipe())
        #expect(library.all.count == ExportRecipeLibrary.builtIns.count)
    }

    @Test func savedRecipesPersistAndSelectionIsRemembered() throws {
        let (library, defaults) = library()
        let saved = try library.save(BatchExportRecipe(longEdgePixels: 1600, format: .png16), as: "  Blog  ")
        #expect(saved.name == "Blog" && library.selected.id == saved.id)

        let reopened = ExportRecipeLibrary(defaults: defaults)
        #expect(reopened.userRecipes.map(\.name) == ["Blog"])
        #expect(reopened.selected.id == saved.id)
        #expect(reopened.selected.recipe.longEdgePixels == 1600 && reopened.selected.recipe.format == .png16)
    }

    @Test func savingUnderAnExistingNameReplacesItAndBuiltInsAreProtected() throws {
        let (library, _) = library()
        try library.save(BatchExportRecipe(longEdgePixels: 1000), as: "Blog")
        try library.save(BatchExportRecipe(longEdgePixels: 1200), as: "blog")
        #expect(library.userRecipes.count == 1 && library.userRecipes[0].recipe.longEdgePixels == 1200)

        #expect(throws: ExportRecipeError.self) { try library.save(BatchExportRecipe(), as: "web, 2048 px") }
        #expect(throws: ExportRecipeError.self) { try library.save(BatchExportRecipe(), as: "   ") }
        #expect(throws: ExportRecipeError.self) { try library.save(BatchExportRecipe(), as: String(repeating: "x", count: 61)) }
        #expect(throws: BatchExportError.self) {
            try library.save(BatchExportRecipe(metadata: ExportMetadataOptions(copyright: "a\nb")), as: "Bad")
        }
    }

    @Test func deletingRemovesOnlyUserRecipesAndFallsBackToTheDefault() throws {
        let (library, defaults) = library()
        let saved = try library.save(BatchExportRecipe(), as: "Temp")
        library.delete(ExportRecipeLibrary.builtIns[1].id)
        #expect(library.all.count == ExportRecipeLibrary.builtIns.count + 1, "a built-in cannot be deleted")
        library.delete(saved.id)
        #expect(library.userRecipes.isEmpty)
        #expect(library.selected.id == ExportRecipeLibrary.builtIns[0].id)
        #expect(ExportRecipeLibrary(defaults: defaults).userRecipes.isEmpty)
    }

    @Test func aSelectedRecipeThatNoLongerExistsFallsBackToTheDefault() {
        let defaults = UserDefaults(suiteName: "pme-export-recipes-\(UUID())")!
        defaults.set(UUID().uuidString, forKey: "perceptionEditor.exportRecipes.selected.v1")
        #expect(ExportRecipeLibrary(defaults: defaults).selected.id == ExportRecipeLibrary.builtIns[0].id)
    }
}
