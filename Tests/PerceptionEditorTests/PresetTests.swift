import Foundation
import Testing
@testable import PerceptionEditor

struct AdjustmentGroupTests {
    private func sample() -> PhotoAdjustments {
        var a = PhotoAdjustments(exposure: 0.5, contrast: 0.2, highlights: -0.3, shadows: 0.4)
        a.temperature = 0.1; a.tint = -0.1; a.vibrance = 0.3; a.saturation = -0.2
        a.sharpness = 0.4; a.vignette = 0.25
        a.raw.temperature = 4800; a.raw.tint = 12
        a.raw.luminanceNoiseReduction = 0.6; a.raw.colorNoiseReduction = 0.3
        a.raw.sharpness = 0.5; a.raw.detail = 1.5; a.raw.lensCorrection = false
        a.curves[.rgb] = ToneCurve.presets[1].curve
        a.hsl = HSLAdjustments(orange: HSLBandAdjustment(hue: 0.2, saturation: 0.1, luminance: 0))
        a.rotationQuarterTurns = 1
        a.cropAspect = .square
        a.cropRect = CropRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        a.straightenDegrees = 2
        return a
    }

    @Test func applyingAGroupCopiesOnlyThatGroup() {
        let source = sample()
        var target = PhotoAdjustments()
        target.exposure = -1
        target.saturation = 0.9
        target.cropAspect = .widescreen

        let result = target.applying(source, groups: [.tone])

        #expect(result.exposure == 0.5 && result.contrast == 0.2)
        #expect(result.saturation == 0.9, "color is not in the tone group")
        #expect(result.cropAspect == .widescreen, "geometry is never part of a group")
        #expect(result.curves.isNeutral && result.hsl == nil && result.raw.isDefault)
    }

    @Test func eachGroupCoversItsOwnSettings() {
        let source = sample()
        let neutral = PhotoAdjustments()

        let wb = neutral.applying(source, groups: [.whiteBalance])
        #expect(wb.raw.temperature == 4800 && wb.raw.tint == 12 && wb.raw.luminanceNoiseReduction == nil && wb.exposure == 0)

        let color = neutral.applying(source, groups: [.color])
        #expect(color.temperature == 0.1 && color.tint == -0.1 && color.vibrance == 0.3 && color.saturation == -0.2)
        #expect(color.raw.temperature == nil, "Warmth is a color setting; Kelvin is white balance")

        let presence = neutral.applying(source, groups: [.presence])
        #expect(presence.sharpness == 0.4 && presence.vignette == 0.25)

        #expect(neutral.applying(source, groups: [.toneCurve]).curves == source.curves)
        #expect(neutral.applying(source, groups: [.hsl]).hsl == source.hsl)

        let detail = neutral.applying(source, groups: [.rawDetail])
        #expect(detail.raw.luminanceNoiseReduction == 0.6 && detail.raw.colorNoiseReduction == 0.3)
        #expect(detail.raw.sharpness == 0.5 && detail.raw.detail == 1.5 && detail.raw.lensCorrection == false)
        #expect(detail.raw.temperature == nil)
    }

    @Test func everySettingBelongsToExactlyOneGroup() {
        // Applying all groups from a fully edited photo reproduces everything except geometry.
        let source = sample()
        let all = PhotoAdjustments().applying(source, groups: Set(AdjustmentGroup.allCases))
        var expected = source
        expected.rotationQuarterTurns = 0
        expected.cropAspect = .original
        expected.cropRect = nil
        expected.straightenDegrees = nil
        #expect(all == expected)
    }

    @Test func lookGroupsLeaveOutWhiteBalanceAndBasicsLeaveOutTheNewPanels() {
        #expect(!AdjustmentGroup.looks.contains(.whiteBalance))
        #expect(AdjustmentGroup.looks.count == AdjustmentGroup.allCases.count - 1)
        #expect(AdjustmentGroup.basics == [.tone, .color, .presence])
    }

    @Test func editedGroupsListsWhatWasTouched() {
        #expect(PhotoAdjustments().editedGroups.isEmpty)
        #expect(sample().editedGroups == Set(AdjustmentGroup.allCases))

        var onlyCurve = PhotoAdjustments()
        onlyCurve.curves[.rgb] = ToneCurve.presets[2].curve
        #expect(onlyCurve.editedGroups == [.toneCurve])
    }

    @Test func changeSummariesNameWhatChanged() {
        let base = PhotoAdjustments()
        var one = base; one.exposure = 0.3
        #expect(one.changeSummary(from: base) == "Exposure")

        var two = one; two.contrast = 0.1
        #expect(two.changeSummary(from: base) == "Exposure, Contrast")

        var many = two; many.saturation = 0.2; many.vignette = 0.1; many.curves[.rgb] = ToneCurve.presets[1].curve
        #expect(many.changeSummary(from: base) == "Exposure, Contrast +3 more")

        var wb = base; wb.raw.temperature = 5000
        #expect(wb.changeSummary(from: base) == "White Balance")
        var crop = base; crop.cropAspect = .square
        #expect(crop.changeSummary(from: base) == "Crop")
        #expect(base.changeSummary(from: base) == "No change")
    }
}

struct PresetModelTests {
    @Test func presetsSavedBeforeGroupsExistedStillLoadAndSetTheBasics() throws {
        let legacy = """
        {"id":"6F4F5E2A-0F7B-4A0A-9E0D-0E9F6E6B1B11","name":"Old","category":"User",
         "adjustments":{"exposure":0.3,"saturation":-0.2}}
        """
        let preset = try JSONDecoder().decode(PhotoPreset.self, from: Data(legacy.utf8))

        #expect(preset.groups == nil)
        #expect(preset.effectiveGroups == AdjustmentGroup.basics)
        #expect(preset.adjustments.exposure == 0.3)
    }

    @Test func aPresetOnlyChangesItsOwnGroups() {
        var photo = PhotoAdjustments()
        photo.curves[.rgb] = ToneCurve.presets[1].curve
        photo.hsl = HSLAdjustments(red: HSLBandAdjustment(hue: 0.3, saturation: 0, luminance: 0))
        photo.raw.temperature = 5200
        photo.raw.luminanceNoiseReduction = 0.7
        photo.cropAspect = .square
        photo.exposure = 1

        let result = PhotoPreset.builtIns[0].apply(to: photo)   // Documentary Warm

        #expect(result.exposure != 1, "its tone settings replace the photo's")
        #expect(result.curves == photo.curves, "curve untouched")
        #expect(result.hsl == photo.hsl, "HSL untouched")
        #expect(result.raw == photo.raw, "white balance and RAW detail untouched")
        #expect(result.cropAspect == .square, "geometry untouched")
    }

    @Test func aPresetWithChosenGroupsSetsThemAndNothingElse() {
        var source = PhotoAdjustments(exposure: 0.8)
        source.saturation = 0.5
        source.curves[.rgb] = ToneCurve.presets[2].curve
        let preset = PhotoPreset(
            name: "Punch", category: "Mine",
            adjustments: source.containing([.tone, .toneCurve]), groups: [.tone, .toneCurve]
        )

        var photo = PhotoAdjustments(exposure: -0.2)
        photo.saturation = -0.3
        let result = preset.apply(to: photo)

        #expect(result.exposure == 0.8)
        #expect(result.curves == source.curves)
        #expect(result.saturation == -0.3)
    }

    @Test func groupsSurviveSaveAndOpen() throws {
        let preset = PhotoPreset(
            name: "X", category: "Y", adjustments: PhotoAdjustments(exposure: 0.1), groups: [.tone, .hsl]
        )
        let decoded = try JSONDecoder().decode(PhotoPreset.self, from: JSONEncoder().encode(preset))
        #expect(decoded == preset)
        #expect(decoded.effectiveGroups == [.tone, .hsl])
    }
}

struct PresetLibraryTests {
    private func preset(_ name: String, _ category: String = "User", exposure: Double = 0) -> PhotoPreset {
        PhotoPreset(name: name, category: category, adjustments: PhotoAdjustments(exposure: exposure), groups: [.tone])
    }

    @Test func presetFilesRoundTrip() throws {
        let presets = [preset("A", exposure: 0.3), preset("B", "Wedding", exposure: -0.2)]
        let data = try PresetLibrary.encode(presets)
        #expect(try PresetLibrary.decode(data) == presets)
    }

    @Test func filesFromANewerFormatAreRefusedClearly() {
        let data = Data("""
        {"format": 99, "presets": []}
        """.utf8)
        #expect(throws: PresetFileError.self) { try PresetLibrary.decode(data) }
        #expect(throws: (any Error).self) { try PresetLibrary.decode(Data("not json".utf8)) }
    }

    @Test func mergingSkipsIdenticalPresetsAndRenamesDifferentOnesWithTheSameName() {
        let existing = [preset("Warm", exposure: 0.2)]
        let incoming = [preset("Warm", exposure: 0.2), preset("Warm", exposure: 0.9), preset("Cool", "Wedding")]

        let result = PresetLibrary.merge(existing: existing, incoming: incoming)

        #expect(result.added == 2 && result.skipped == 1)
        let names = result.presets.map(\.name)
        #expect(names.contains("Warm") && names.contains("Warm (2)") && names.contains("Cool"))
        #expect(result.presets.count == 3)
    }

    @Test func importedPresetsGetTheirOwnIdentity() {
        let incoming = preset("Imported")
        let result = PresetLibrary.merge(existing: [], incoming: [incoming])
        #expect(result.presets.first?.id != incoming.id)
    }

    @Test func uniqueNamesAreScopedToACategory() {
        let presets = [preset("Warm", "A"), preset("Warm (2)", "A")]
        #expect(PresetLibrary.uniqueName("Warm", category: "A", in: presets) == "Warm (3)")
        #expect(PresetLibrary.uniqueName("Warm", category: "B", in: presets) == "Warm")
        #expect(PresetLibrary.uniqueName("warm", category: "A", in: presets) == "warm (2)".replacingOccurrences(of: "(2)", with: "(3)"))
    }

    @Test func categoriesListBuiltInsFirstThenTheUsersOwnAlphabetically() {
        let user = [preset("x", "Zebra"), preset("y", "Apple"), preset("z", "Perception")]
        let categories = PresetLibrary.categories(builtIn: PhotoPreset.builtIns, user: user)

        #expect(Array(categories.prefix(PhotoPreset.builtIns.count)) == PhotoPreset.builtIns.map(\.category))
        #expect(categories.suffix(2) == ["Apple", "Zebra"])
        #expect(Set(categories).count == categories.count)
    }
}

@MainActor
struct PresetStoreTests {
    private func makeStore(photos: Int = 3) -> (EditorStore, [MediaAsset]) {
        let suite = "pme-tests-\(UUID().uuidString)"
        let store = EditorStore(presetRepository: UserPresetRepository(defaults: UserDefaults(suiteName: suite)!))
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        let assets = (0 ..< photos).map { index in
            MediaAsset(
                url: URL(fileURLWithPath: "/Volumes/Test/P\(1000 + index).RW2"),
                captureDate: base.addingTimeInterval(Double(index) * 10)
            )
        }
        store.project.media = assets
        for asset in assets { store.project.adjustmentsByAssetID[asset.id] = .neutral }
        store.select(store.allPhotos[0])
        return (store, assets)
    }

    // MARK: Applying

    @Test func applyingAPresetToTheSelectionIsOneUndoStep() {
        let (store, _) = makeStore()
        let photos = store.allPhotos
        store.select(photos[0])
        store.extendSelection(to: photos[2])

        store.apply(PhotoPreset.builtIns[0])

        for photo in photos {
            #expect(store.project.adjustmentsByAssetID[photo.id]?.exposure == PhotoPreset.builtIns[0].adjustments.exposure)
        }
        store.undoPhotoEdit()
        for photo in photos {
            #expect(store.project.adjustmentsByAssetID[photo.id] == .neutral)
        }
        #expect(!store.canUndoPhotoEdit)
    }

    @Test func aPresetLeavesEachPhotosOwnGeometryAndWhiteBalance() {
        let (store, _) = makeStore()
        let photos = store.allPhotos
        store.updateAdjustments { $0.cropAspect = .square; $0.raw.temperature = 6000 }
        store.select(photos[1])
        store.updateAdjustments { $0.raw.temperature = 3200 }
        store.select(photos[0])
        store.extendSelection(to: photos[1])

        store.apply(PhotoPreset.builtIns[1])

        #expect(store.project.adjustmentsByAssetID[photos[0].id]?.cropAspect == .square)
        #expect(store.project.adjustmentsByAssetID[photos[0].id]?.raw.temperature == 6000)
        #expect(store.project.adjustmentsByAssetID[photos[1].id]?.raw.temperature == 3200)
    }

    @Test func applyingToOnePhotoWithNothingSelectedDoesNothing() {
        let (store, _) = makeStore()
        store.selectedAssetID = nil
        store.selectedAssetIDs = []
        store.apply(PhotoPreset.builtIns[0])
        #expect(!store.canUndoPhotoEdit)
    }

    // MARK: User presets

    @Test func savingCapturesOnlyTheChosenGroups() throws {
        let (store, _) = makeStore()
        store.updateAdjustments {
            $0.exposure = 0.7; $0.saturation = 0.4
            $0.curves[.rgb] = ToneCurve.presets[1].curve
            $0.raw.temperature = 4400
        }

        let saved = try #require(store.saveUserPreset(named: "  Punch  ", category: "Wedding", groups: [.tone, .toneCurve]))

        #expect(saved.name == "Punch" && saved.category == "Wedding")
        #expect(saved.groups == [.tone, .toneCurve])
        #expect(saved.adjustments.exposure == 0.7)
        #expect(saved.adjustments.saturation == 0, "color was not chosen")
        #expect(saved.adjustments.raw.temperature == nil, "white balance was not chosen")
        #expect(store.presets.contains { $0.id == saved.id })
    }

    @Test func savingWithNoNameOrNoGroupsIsRefused() {
        let (store, _) = makeStore()
        #expect(store.saveUserPreset(named: "   ", groups: [.tone]) == nil)
        #expect(store.saveUserPreset(named: "X", groups: []) == nil)
        #expect(store.userPresets.isEmpty)
    }

    @Test func savingUnderAnExistingNameReplacesItButOtherCategoriesAreSeparate() throws {
        let (store, _) = makeStore()
        store.updateAdjustments { $0.exposure = 0.3 }
        let first = try #require(store.saveUserPreset(named: "Look", category: "A", groups: [.tone]))
        store.updateAdjustments { $0.exposure = 0.9 }
        let second = try #require(store.saveUserPreset(named: "look", category: "A", groups: [.tone]))
        let other = try #require(store.saveUserPreset(named: "Look", category: "B", groups: [.tone]))

        #expect(second.id == first.id)
        #expect(store.userPresets.count == 2)
        #expect(store.userPresets.first { $0.id == first.id }?.adjustments.exposure == 0.9)
        #expect(other.id != first.id)
    }

    @Test func presetsPersistAcrossLaunches() throws {
        let suite = "pme-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let first = EditorStore(presetRepository: UserPresetRepository(defaults: defaults))
        let asset = MediaAsset(url: URL(fileURLWithPath: "/x/P1.RW2"))
        first.project.media = [asset]
        first.select(asset)
        first.updateAdjustments { $0.exposure = 0.4 }
        first.saveUserPreset(named: "Keep", category: "Mine", groups: [.tone])

        let second = EditorStore(presetRepository: UserPresetRepository(defaults: defaults))
        let loaded = try #require(second.userPresets.first)
        #expect(loaded.name == "Keep" && loaded.category == "Mine" && loaded.groups == [.tone])
    }

    @Test func renamingMovingAndDeleting() throws {
        let (store, _) = makeStore()
        store.updateAdjustments { $0.exposure = 0.3 }
        let a = try #require(store.saveUserPreset(named: "A", category: "One", groups: [.tone]))
        let b = try #require(store.saveUserPreset(named: "B", category: "Two", groups: [.tone]))

        store.renameUserPreset(a, to: "  Renamed ")
        #expect(store.userPresets.first { $0.id == a.id }?.name == "Renamed")

        store.moveUserPreset(a, toCategory: "Two")
        #expect(store.userPresets.first { $0.id == a.id }?.name == "Renamed", "moving keeps the new name")
        store.renameUserPreset(b, to: "Renamed")
        #expect(Set(store.presets(in: "Two").map(\.name)) == ["Renamed", "Renamed (2)"], "names stay unique within a category")

        store.deleteUserPreset(b)
        #expect(!store.isUserPreset(b))
        #expect(store.isUserPreset(a))
        #expect(!store.presetCategories.contains("One"), "an emptied category disappears")
    }

    @Test func updatingAPresetTakesTheCurrentSettings() throws {
        let (store, _) = makeStore()
        store.updateAdjustments { $0.exposure = 0.3 }
        let preset = try #require(store.saveUserPreset(named: "A", groups: [.tone]))
        store.updateAdjustments { $0.exposure = -0.6; $0.saturation = 0.5 }

        store.updateUserPreset(preset, groups: [.tone, .color])

        let updated = try #require(store.userPresets.first)
        #expect(updated.adjustments.exposure == -0.6 && updated.adjustments.saturation == 0.5)
        #expect(updated.groups == [.tone, .color])
    }

    @Test func importingPresetFilesAddsThemAndReportsDuplicates() throws {
        let (store, _) = makeStore()
        let temp = try TempDirectory()
        let presets = [
            PhotoPreset(name: "Filmic", category: "Imported", adjustments: PhotoAdjustments(exposure: 0.1), groups: [.tone]),
            PhotoPreset(name: "Faded", category: "Imported", adjustments: PhotoAdjustments(contrast: -0.2), groups: [.tone])
        ]
        let file = temp.url.appendingPathComponent("pack.pmpreset")
        try PresetLibrary.encode(presets).write(to: file)

        store.importPresets(from: [file])
        #expect(store.userPresets.count == 2)
        #expect(store.presets(in: "Imported").count == 2)

        store.importPresets(from: [file])
        #expect(store.userPresets.count == 2, "importing the same file again adds nothing")
        #expect(store.statusMessage.contains("already in your library"))

        let bad = temp.url.appendingPathComponent("bad.pmpreset")
        try Data("nope".utf8).write(to: bad)
        store.importPresets(from: [bad])
        #expect(store.lastError?.contains("bad.pmpreset") == true)
        #expect(store.userPresets.count == 2)
    }

    // MARK: Copy, paste, sync

    @Test func copiedGroupsPasteOntoEverySelectedPhoto() {
        let (store, _) = makeStore(photos: 4)
        let photos = store.allPhotos
        store.select(photos[0])
        store.updateAdjustments { $0.exposure = 0.5; $0.saturation = 0.3; $0.raw.temperature = 4200 }
        store.copySettings(groups: [.tone])
        #expect(store.canPasteSettings)

        store.select(photos[1])
        store.updateAdjustments { $0.saturation = -0.4 }
        store.extendSelection(to: photos[3])
        store.pasteSettings()

        for photo in photos[1 ... 3] {
            let adjustments = store.project.adjustmentsByAssetID[photo.id]
            #expect(adjustments?.exposure == 0.5)
            #expect(adjustments?.raw.temperature == nil, "white balance was not copied")
        }
        #expect(store.project.adjustmentsByAssetID[photos[1].id]?.saturation == -0.4, "color was not copied")
        #expect(store.project.adjustmentsByAssetID[photos[0].id]?.exposure == 0.5)

        store.undoPhotoEdit()
        #expect(store.project.adjustmentsByAssetID[photos[2].id]?.exposure == 0)
    }

    @Test func pastingWithNothingCopiedDoesNothing() {
        let (store, _) = makeStore()
        #expect(!store.canPasteSettings)
        store.pasteSettings()
        #expect(!store.canUndoPhotoEdit)
    }

    @Test func syncCopiesTheCurrentPhotoToTheOthersInTheSelection() {
        let (store, _) = makeStore(photos: 3)
        let photos = store.allPhotos
        store.select(photos[0])
        store.updateAdjustments { $0.exposure = 0.8; $0.raw.temperature = 5000 }
        store.extendSelection(to: photos[2])

        store.syncSettings(groups: [.tone, .whiteBalance])

        for photo in photos {
            #expect(store.project.adjustmentsByAssetID[photo.id]?.exposure == 0.8)
            #expect(store.project.adjustmentsByAssetID[photo.id]?.raw.temperature == 5000)
        }
    }

    @Test func syncWithASinglePhotoExplainsInsteadOfDoingNothingSilently() {
        let (store, _) = makeStore()
        store.updateAdjustments { $0.exposure = 0.8 }
        store.syncSettings(groups: [.tone])
        #expect(store.statusMessage.contains("Select more photos"))
    }

    // MARK: History

    @Test func editsAreRecordedWithNamesAndAStartingPoint() {
        let (store, _) = makeStore()
        store.updateAdjustments { $0.exposure = 0.3 }
        store.updateAdjustments { $0.contrast = 0.1; $0.saturation = 0.2 }

        let history = store.selectedHistory
        #expect(history.map(\.name) == ["Start", "Exposure", "Contrast, Saturation"])
        #expect(history[0].adjustments == .neutral)
        #expect(history[2].adjustments == store.selectedAdjustments)
    }

    @Test func aSliderDragIsOneHistoryStep() {
        let (store, _) = makeStore()
        store.beginAdjustmentEdit()
        for value in stride(from: 0.0, through: 1.0, by: 0.1) {
            store.updateAdjustments { $0.exposure = value }
        }
        store.endAdjustmentEdit()

        #expect(store.selectedHistory.map(\.name) == ["Start", "Exposure"])
    }

    @Test func presetsPasteAndRestoresAreNamedAndRecordedForEveryPhoto() {
        let (store, _) = makeStore()
        let photos = store.allPhotos
        store.select(photos[0])
        store.extendSelection(to: photos[1])
        store.apply(PhotoPreset.builtIns[0])

        #expect(store.history[photos[0].id]?.last?.name == "Preset: Documentary Warm")
        #expect(store.history[photos[1].id]?.last?.name == "Preset: Documentary Warm")
        #expect(store.history[photos[2].id] == nil)
    }

    @Test func restoringAStepGoesBackAndIsItselfUndoable() throws {
        let (store, _) = makeStore()
        store.updateAdjustments { $0.exposure = 0.3 }
        store.updateAdjustments { $0.exposure = 0.9 }
        let target = try #require(store.selectedHistory.first { $0.name == "Exposure" })

        store.restoreHistory(target)

        #expect(store.selectedAdjustments.exposure == 0.3 || store.selectedAdjustments == target.adjustments)
        #expect(store.selectedHistory.last?.name == "Back to Exposure")
        #expect(store.selectedHistory.count == 4, "history is added to, never rewritten")

        store.undoPhotoEdit()
        #expect(store.selectedAdjustments.exposure == 0.9)
    }

    @Test func restoringTheCurrentStateChangesNothing() throws {
        let (store, _) = makeStore()
        store.updateAdjustments { $0.exposure = 0.3 }
        let count = store.selectedHistory.count
        store.restoreHistory(try #require(store.selectedHistory.last))
        #expect(store.selectedHistory.count == count)
    }

    @Test func historyKeepsItsStartAndTheMostRecentSteps() {
        let (store, _) = makeStore()
        for step in 1 ... HistoryEntry.limit + 20 {
            store.updateAdjustments { $0.exposure = Double(step) / 1000 }
        }
        let history = store.selectedHistory
        #expect(history.count == HistoryEntry.limit)
        #expect(history.first?.name == "Start")
        #expect(history.last?.adjustments == store.selectedAdjustments)
    }

    @Test func historyIsClearedWhenTheProjectChanges() {
        let (store, _) = makeStore()
        store.updateAdjustments { $0.exposure = 0.3 }
        #expect(!store.selectedHistory.isEmpty)
        store.resetToEmptyProject(named: "New")
        #expect(store.history.isEmpty)
    }
}
