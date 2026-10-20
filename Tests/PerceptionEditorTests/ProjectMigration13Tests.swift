import Foundation
import Testing
@testable import PerceptionEditor

/// Schema 13: photos carry a process version. Files saved earlier have none and must keep rendering
/// with version 1; new photos start on the newest process.
struct ProjectMigration13Tests {
    private let document = ProjectDocument()

    @Test func adjustmentsWithoutAVersionDecodeAsProcessOne() throws {
        let json = Data(#"{ "exposure": 0.5, "contrast": 0.2 }"#.utf8)
        let decoded = try JSONDecoder().decode(PhotoAdjustments.self, from: json)
        #expect(decoded.processVersion == 1)
        #expect(decoded.exposure == 0.5 && decoded.contrast == 0.2)
    }

    @Test func theProcessVersionRoundTrips() throws {
        let fresh = PhotoAdjustments()
        #expect(fresh.processVersion == PhotoAdjustments.currentProcessVersion)
        for version in 1...PhotoAdjustments.newestProcessVersion {
            var adjustments = PhotoAdjustments()
            adjustments.processVersion = version
            let data = try JSONEncoder().encode(adjustments)
            #expect(try JSONDecoder().decode(PhotoAdjustments.self, from: data).processVersion == version)
        }
    }

    @Test func theDecodeModeFollowsTheProcessVersion() {
        var adjustments = PhotoAdjustments()
        adjustments.processVersion = 1
        #expect(!adjustments.decodeSettings.sceneLinear)
        adjustments.processVersion = 2
        #expect(adjustments.decodeSettings.sceneLinear)
        #expect(adjustments.decodeSettings.isDefault, "The decode mode alone is not a RAW edit")
        #expect(adjustments.decodeSettings.cacheKey != RawSettings().cacheKey)
    }

    @Test func aSchema12ProjectKeepsItsPhotosOnProcessOneAndSavesAsSchema13() throws {
        let assetID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        let project = Data("""
        {
          "schemaVersion": 12,
          "id": "00000000-0000-0000-0000-000000000001",
          "name": "Schema 12 Shoot",
          "createdAt": "2026-10-01T12:00:00Z",
          "updatedAt": "2026-10-01T12:00:00Z",
          "media": [{ "id": "\(assetID)", "url": "file:///Volumes/Card/P1107158.RW2", "kind": "photo" }],
          "adjustmentsByAssetID": ["\(assetID)", { "exposure": 0.7, "highlights": -0.3 }]
        }
        """.utf8)
        let opened = try document.project(from: project)
        let adjustments = try #require(opened.adjustmentsByAssetID[assetID])
        #expect(adjustments.processVersion == 1)
        #expect(adjustments.exposure == 0.7)

        let saved = try document.data(for: opened)
        let reopened = try document.project(from: saved)
        #expect(reopened.schemaVersion == 13)
        #expect(reopened.adjustmentsByAssetID[assetID]?.processVersion == 1, "Saving must not upgrade an existing edit")
    }

    @Test func untouchedIgnoresTheProcessVersion() {
        var legacy = PhotoAdjustments()
        legacy.processVersion = 1
        #expect(legacy.isUntouched)
        legacy.exposure = 0.1
        #expect(!legacy.isUntouched)
    }
}
