import Foundation
import Testing
@testable import PerceptionEditor

struct CullingModelTests {
    @Test func keysMatchLightroom() {
        #expect(CullKeyMap.command(for: "p") == .flag(.picked))
        #expect(CullKeyMap.command(for: "P") == .flag(.picked))
        #expect(CullKeyMap.command(for: "x") == .flag(.rejected))
        #expect(CullKeyMap.command(for: "u") == .flag(.unflagged))
        #expect(CullKeyMap.command(for: "0") == .rating(0))
        #expect(CullKeyMap.command(for: "5") == .rating(5))
        #expect(CullKeyMap.command(for: "6") == .toggleLabel(.red))
        #expect(CullKeyMap.command(for: "9") == .toggleLabel(.blue))
        #expect(CullKeyMap.command(for: CullKeyMap.rightArrow) == .next)
        #expect(CullKeyMap.command(for: CullKeyMap.leftArrow) == .previous)
        #expect(CullKeyMap.command(for: "c") == .toggleCompare)
        #expect(CullKeyMap.command(for: "d") == .openInDevelop)
        #expect(CullKeyMap.command(for: "z") == nil)
        #expect(CullKeyMap.command(for: "55") == nil)
        #expect(CullKeyMap.command(for: "") == nil)
    }

    @Test func filterCombinesFlagRatingAndLabel() {
        let url = URL(fileURLWithPath: "/x.RW2")
        let good = MediaAsset(url: url, rating: 4, flag: .picked, colorLabel: .green)
        let plain = MediaAsset(url: url)

        #expect(LibraryFilter().matches(plain))
        #expect(!LibraryFilter().isActive)

        #expect(LibraryFilter(flags: [.picked]).matches(good))
        #expect(!LibraryFilter(flags: [.picked]).matches(plain))
        #expect(LibraryFilter(minimumRating: 4).matches(good))
        #expect(!LibraryFilter(minimumRating: 5).matches(good))
        #expect(LibraryFilter(colorLabels: [.green, .red]).matches(good))
        #expect(!LibraryFilter(colorLabels: [.green]).matches(plain))
        #expect(LibraryFilter(flags: [.picked], minimumRating: 3, colorLabels: [.green]).matches(good))
        #expect(!LibraryFilter(flags: [.rejected], minimumRating: 3).matches(good))
    }

    @Test func olderProjectsWithoutCullingFieldsStillOpen() throws {
        let asset = MediaAsset(url: URL(fileURLWithPath: "/x/P1.RW2"), rating: 3, flag: .picked, colorLabel: .red)
        let project = EditorProject(name: "Old", media: [asset])
        let document = ProjectDocument()

        var object = try #require(try JSONSerialization.jsonObject(with: document.data(for: project)) as? [String: Any])
        var media = try #require(object["media"] as? [[String: Any]])
        for key in ["flag", "colorLabel", "captureDate"] { media[0].removeValue(forKey: key) }
        object["media"] = media
        object["schemaVersion"] = 4

        let decoded = try document.project(from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.media[0].flag == .unflagged)
        #expect(decoded.media[0].colorLabel == nil)
        #expect(decoded.media[0].captureDate == nil)
        #expect(decoded.media[0].rating == 3)
    }

    @Test func cullingStateSurvivesSaveAndOpen() throws {
        let stamp = Date(timeIntervalSince1970: 1_780_000_000)
        let asset = MediaAsset(
            url: URL(fileURLWithPath: "/x/P1.RW2"), rating: 5, flag: .rejected, colorLabel: .purple, captureDate: stamp
        )
        let document = ProjectDocument()
        let decoded = try document.project(from: document.data(for: EditorProject(name: "New", media: [asset])))

        #expect(decoded.media[0].flag == .rejected)
        #expect(decoded.media[0].colorLabel == .purple)
        #expect(decoded.media[0].rating == 5)
        #expect(abs(decoded.media[0].captureDate!.timeIntervalSince(stamp)) < 1)
    }
}

@MainActor
struct CullingStoreTests {
    /// Five photos taken out of filename order, so capture-time sorting is visible.
    private func makeStore(count: Int = 5) -> (EditorStore, [MediaAsset]) {
        let store = EditorStore()
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        let assets = (0 ..< count).map { index in
            MediaAsset(
                url: URL(fileURLWithPath: "/Volumes/Test/Originals/P\(1000 + index).RW2"),
                captureDate: base.addingTimeInterval(Double(count - index) * 10)
            )
        }
        store.project.media = assets
        for asset in assets { store.project.adjustmentsByAssetID[asset.id] = .neutral }
        store.select(store.allPhotos[0])
        return (store, assets)
    }

    @Test func photosAreShownInCaptureOrder() {
        let (store, assets) = makeStore()
        // The asset with the highest index was captured first.
        #expect(store.allPhotos.map(\.id) == assets.reversed().map(\.id))
    }

    @Test func ratingFlagAndLabelApplyToTheSelectedPhoto() {
        let (store, _) = makeStore()
        let id = store.selectedAssetID!

        store.perform(.rating(4))
        store.perform(.flag(.picked))
        store.perform(.toggleLabel(.blue))

        let asset = store.project.media.first { $0.id == id }!
        #expect(asset.rating == 4)
        #expect(asset.flag == .picked)
        #expect(asset.colorLabel == .blue)
        #expect(store.project.media.filter { $0.id != id }.allSatisfy { $0.rating == 0 && $0.flag == .unflagged })
    }

    @Test func ratingIsClampedAndLabelsToggleOff() {
        let (store, _) = makeStore()
        store.setRating(9)
        #expect(store.selectedAsset?.rating == 5)
        store.setRating(-3)
        #expect(store.selectedAsset?.rating == 0)

        store.toggleLabel(.red)
        #expect(store.selectedAsset?.colorLabel == .red)
        store.toggleLabel(.red)
        #expect(store.selectedAsset?.colorLabel == nil)
    }

    @Test func commandsApplyToTheWholeMultiSelection() {
        let (store, _) = makeStore()
        let photos = store.allPhotos
        store.select(photos[0])
        store.extendSelection(to: photos[2])
        #expect(store.selectedAssetIDs.count == 3)

        store.perform(.flag(.rejected))

        let rejected = store.project.media.filter { $0.flag == .rejected }
        #expect(Set(rejected.map(\.id)) == Set(photos[0 ... 2].map(\.id)))
    }

    @Test func navigationStopsAtTheEnds() {
        let (store, _) = makeStore()
        let photos = store.allPhotos
        store.select(photos[0])

        store.perform(.previous)
        #expect(store.selectedAssetID == photos[0].id)

        for _ in 0 ..< 10 { store.perform(.next) }
        #expect(store.selectedAssetID == photos[4].id)
        #expect(store.selectedPosition == 5)
    }

    @Test func autoAdvanceMovesOnAfterFlaggingInTheCullView() {
        let (store, _) = makeStore()
        let photos = store.allPhotos
        store.workspace = .cull
        store.select(photos[0])

        store.autoAdvance = false
        store.perform(.flag(.picked))
        #expect(store.selectedAssetID == photos[0].id)

        store.autoAdvance = true
        store.perform(.flag(.rejected))
        #expect(store.selectedAssetID == photos[1].id)
        store.autoAdvance = false
    }

    @Test func filteringHidesPhotosAndKeepsAValidSelection() {
        let (store, _) = makeStore()
        let photos = store.allPhotos
        store.setRating(5, for: [photos[3].id])
        store.select(photos[0])

        store.filter.minimumRating = 5

        #expect(store.visiblePhotos.map(\.id) == [photos[3].id])
        #expect(store.selectedAssetID == photos[3].id)
        #expect(store.allPhotos.count == 5)
    }

    @Test func removingThePhotoUnderTheSelectionMovesToItsNeighbor() {
        let (store, _) = makeStore()
        let photos = store.allPhotos
        store.select(photos[2])

        store.removeFromProject([photos[2].id])

        #expect(store.allPhotos.count == 4)
        #expect(store.selectedAssetID == photos[3].id)
        #expect(store.project.adjustmentsByAssetID[photos[2].id] == nil)
    }

    @Test func rejectedPhotosOnlyQualifyForTheTrashInsideTheShootsOriginalsFolder() throws {
        let temp = try TempDirectory()
        let (store, _) = makeStore(count: 3)
        store.projectURL = temp.url.appendingPathComponent("Shoot/Shoot.pmedit")
        let inside = MediaAsset(
            url: temp.url.appendingPathComponent("Shoot/Originals/P1.RW2"), flag: .rejected
        )
        let outside = MediaAsset(url: URL(fileURLWithPath: "/Volumes/Other/Lightroom/P2.RW2"), flag: .rejected)
        // A folder that only shares a prefix with the shoot must not count as inside it.
        let lookalike = MediaAsset(
            url: temp.url.appendingPathComponent("Shoot/Originals-old/P3.RW2"), flag: .rejected
        )
        store.project.media += [inside, outside, lookalike]

        #expect(store.rejectedCount == 3)
        #expect(store.trashableRejects.map(\.id) == [inside.id])
    }

    @Test func projectsWithAFileSaveThemselvesAndSkipTheDiscardPrompt() throws {
        let temp = try TempDirectory()
        let (store, _) = makeStore(count: 2)
        let file = temp.url.appendingPathComponent("Shoot.pmedit")
        store.projectURL = file

        store.perform(.rating(3))
        #expect(store.hasUnsavedChanges)

        store.autosaveIfNeeded()
        #expect(!store.hasUnsavedChanges)
        let saved = try ProjectDocument().load(from: file)
        #expect(saved.media.contains { $0.rating == 3 })

        // With a file on disk, leaving the project never asks.
        store.perform(.rating(1))
        #expect(store.confirmDiscardingUnsavedChanges())
        #expect(try ProjectDocument().load(from: file).media.contains { $0.rating == 1 })
    }

    @Test func keysOnlyReachTheCommandsThatMakeSenseInEachWorkspace() {
        let (store, _) = makeStore()

        store.workspace = .cull
        #expect(store.handleKey("p"))
        #expect(store.handleKey(CullKeyMap.rightArrow))

        store.workspace = .photo
        #expect(store.handleKey("3"))
        // Arrow keys belong to the sliders and crop editor in Develop.
        #expect(!store.handleKey(CullKeyMap.rightArrow))
        #expect(!store.handleKey("c"))

        store.workspace = .video
        #expect(!store.handleKey("p"))

        store.workspace = .cull
        store.select(store.allPhotos[0])
        store.project.media = []
        store.selectedAssetID = nil
        #expect(!store.handleKey("p"))
    }
}
