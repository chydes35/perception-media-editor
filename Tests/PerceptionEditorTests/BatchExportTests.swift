import Foundation
import Testing
import UniformTypeIdentifiers
@testable import PerceptionEditor

struct BatchExportTests {
    @Test func recipeRejectsUnsafeNamesAndOutOfRangeSettings() {
        #expect(throws: BatchExportError.self) {
            try BatchExportRecipe(jpegQuality: .nan).validate()
        }
        #expect(throws: BatchExportError.self) {
            try BatchExportRecipe(longEdgePixels: -1).validate()
        }
        #expect(throws: BatchExportError.self) {
            try BatchExportRecipe(filenameSuffix: "/../source").validate()
        }
    }

    @Test func plannerNumbersExistingNamesAndNeverChoosesAnOriginal() throws {
        let temp = try TempDirectory()
        let original = try writeTestJPEG(to: temp.url.appendingPathComponent("photo.jpg"))
        try Data("previous output".utf8).write(to: temp.url.appendingPathComponent("photo_edited.jpg"))
        let item = BatchExportItem(id: UUID(), source: original, adjustments: .neutral)
        var reserved = Set<String>()
        let first = try BatchExportPlanner.destination(
            for: item, in: temp.url, suffix: "_edited", reserved: &reserved, protecting: [original]
        )
        let second = try BatchExportPlanner.destination(
            for: item, in: temp.url, suffix: "_edited", reserved: &reserved, protecting: [original]
        )
        #expect(first.lastPathComponent == "photo_edited-2.jpg")
        #expect(second.lastPathComponent == "photo_edited-3.jpg")

        var noSuffix = Set<String>()
        let protected = try BatchExportPlanner.destination(
            for: item, in: temp.url, suffix: "", reserved: &noSuffix, protecting: [original]
        )
        #expect(protected.lastPathComponent == "photo-2.jpg")
    }

    @Test func lateNameCollisionCannotReplaceAnExistingDeliverable() throws {
        let temp = try TempDirectory()
        let output = temp.url.appendingPathComponent("delivery.jpg")
        let existing = Data("created during rendering".utf8)
        #expect(throws: ExportFileError.destinationExists) {
            try ExportFileSafety.writeAtomically(
                to: output, protecting: [], replaceExisting: false
            ) { temporary in
                try Data("new output".utf8).write(to: temporary)
                try existing.write(to: output)
            }
        }
        #expect(try Data(contentsOf: output) == existing)
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.url.path) == ["delivery.jpg"])
    }

    @Test func jpegLongEdgeDownscalesWithoutUpscaling() async throws {
        let temp = try TempDirectory()
        let source = try writeTestJPEG(to: temp.url.appendingPathComponent("source.jpg"))
        let output = temp.url.appendingPathComponent("small.jpg")
        try await PhotoRenderer().export(
            url: source, adjustments: .neutral, to: output, type: .jpeg,
            quality: 0.7, longEdgePixels: 200, replaceExisting: false
        )
        #expect(PhotoSourceLoader.dimensions(of: output).map { [$0.width, $0.height] } == [200, 150])
        let full = temp.url.appendingPathComponent("full.jpg")
        try await PhotoRenderer().export(
            url: source, adjustments: .neutral, to: full, type: .jpeg,
            longEdgePixels: 1000, replaceExisting: false
        )
        #expect(PhotoSourceLoader.dimensions(of: full).map { [$0.width, $0.height] } == [400, 300])
    }
}

@MainActor
struct BatchExportStoreTests {
    @Test func selectionExportsInProjectOrderWithUniqueNamesAndResults() async throws {
        let temp = try TempDirectory()
        let sourceA = try temp.subdirectory("a")
        let sourceB = try temp.subdirectory("b")
        let output = try temp.subdirectory("delivery")
        let firstURL = try writeTestJPEG(to: sourceA.appendingPathComponent("same.jpg"))
        let secondURL = try writeTestJPEG(to: sourceB.appendingPathComponent("same.jpg"))
        let existing = output.appendingPathComponent("same_edited.jpg")
        let bytes = Data("keep this output".utf8)
        try bytes.write(to: existing)
        let store = EditorStore()
        let first = MediaAsset(url: firstURL)
        let second = MediaAsset(url: secondURL)
        store.project.media = [first, second]
        store.selectedAssetID = second.id
        store.selectedAssetIDs = [first.id, second.id]

        let task = try store.startBatchExport(to: output, recipe: BatchExportRecipe(longEdgePixels: 200))
        await task.value

        #expect(store.batchExportState.completed == 2)
        #expect(store.batchExportState.results.map(\.id) == [first.id, second.id])
        let allSucceeded = store.batchExportState.results.allSatisfy { $0.succeeded }
        #expect(allSucceeded)
        #expect(store.batchExportState.results.compactMap(\.output).map(\.lastPathComponent)
                == ["same_edited-2.jpg", "same_edited-3.jpg"])
        #expect(try Data(contentsOf: existing) == bytes)
        #expect(store.isExporting == false)
    }

    @Test func cancellingBeforeQueueStartsPublishesNothing() async throws {
        let temp = try TempDirectory()
        let output = try temp.subdirectory("delivery")
        let source = try writeTestJPEG(to: temp.url.appendingPathComponent("source.jpg"))
        let store = EditorStore()
        let asset = MediaAsset(url: source)
        store.project.media = [asset]
        store.selectedAssetID = asset.id
        store.selectedAssetIDs = [asset.id]
        let task = try store.startBatchExport(to: output, recipe: BatchExportRecipe())
        store.cancelBatchExport()
        await task.value
        #expect(store.batchExportState.wasCancelled)
        #expect(store.batchExportState.completed == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
    }
}
