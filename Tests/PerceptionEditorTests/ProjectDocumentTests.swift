import Foundation
import Testing
@testable import PerceptionEditor

/// Round-trip and migration coverage for the `.pmedit` format (formerly scripts/model-check.swift).
struct ProjectDocumentTests {
    private let document = ProjectDocument()

    private func makeProject() -> (EditorProject, MediaAsset, TimelineClip) {
        let assetID = UUID()
        let asset = MediaAsset(
            id: assetID,
            url: URL(fileURLWithPath: "/Volumes/Media/P1000001.RW2"),
            pixelWidth: 6000,
            pixelHeight: 4000
        )
        let adjustments = PhotoAdjustments(
            exposure: 0.45,
            contrast: 0.08,
            highlights: -0.32,
            shadows: 0.22,
            temperature: 0.12,
            cropAspect: .portrait,
            cropRect: CropRect(x: 0.1, y: 0.12, width: 0.72, height: 0.68),
            straightenDegrees: -2.4
        )
        let clip = TimelineClip(assetID: assetID, sourceStartFrame: 48, durationFrames: 300)
        let project = EditorProject(
            name: "Documentary",
            media: [asset],
            adjustmentsByAssetID: [assetID: adjustments],
            videoAdjustmentsByClipID: [clip.id: PhotoAdjustments(exposure: 0.35, vibrance: 0.16)],
            audioAdjustmentsByClipID: [clip.id: ClipAudioAdjustments(gainDecibels: -2.85, pan: -0.2, fadeInSeconds: 0.8, fadeOutSeconds: 1.1)],
            timelineClips: [clip]
        )
        return (project, asset, clip)
    }

    @Test func projectRoundTrips() throws {
        let (project, asset, clip) = makeProject()
        let decoded = try document.project(from: document.data(for: project))

        #expect(decoded.name == project.name)
        // Dates are stored as ISO 8601 whole seconds, so compare everything else exactly.
        let decodedAsset = try #require(decoded.media.first)
        #expect(decoded.media.count == 1)
        #expect(decodedAsset.id == asset.id)
        #expect(decodedAsset.url == asset.url)
        #expect(decodedAsset.pixelWidth == 6000 && decodedAsset.pixelHeight == 4000)
        #expect(abs(decodedAsset.importedAt.timeIntervalSince(asset.importedAt)) < 1)
        #expect(decoded.adjustmentsByAssetID == project.adjustmentsByAssetID)
        #expect(decoded.timelineClips == [clip])
        #expect(decoded.videoAdjustmentsByClipID == project.videoAdjustmentsByClipID)
        #expect(decoded.audioAdjustmentsByClipID == project.audioAdjustmentsByClipID)
        #expect(decoded.schemaVersion == EditorProject.currentSchemaVersion)
    }

    @Test func olderSchemasDecodeWithDefaults() throws {
        let (project, _, _) = makeProject()
        var object = try #require(
            try JSONSerialization.jsonObject(with: document.data(for: project)) as? [String: Any]
        )

        object["schemaVersion"] = 3
        object.removeValue(forKey: "audioAdjustmentsByClipID")
        let schemaThree = try document.project(from: JSONSerialization.data(withJSONObject: object))
        #expect(schemaThree.audioAdjustmentsByClipID.isEmpty)

        object["schemaVersion"] = 2
        object.removeValue(forKey: "videoAdjustmentsByClipID")
        let schemaTwo = try document.project(from: JSONSerialization.data(withJSONObject: object))
        #expect(schemaTwo.videoAdjustmentsByClipID.isEmpty)
    }

    @Test func futureSchemaIsRejected() {
        let future = Data("""
        {
          "schemaVersion": 999,
          "id": "00000000-0000-0000-0000-000000000001",
          "name": "Future Project",
          "createdAt": "2026-09-25T12:00:00Z",
          "updatedAt": "2026-09-25T12:00:00Z",
          "media": [],
          "adjustmentsByAssetID": []
        }
        """.utf8)

        #expect(throws: ProjectDocumentError.self) {
            try document.project(from: future)
        }
    }

    @Test func builtInPresetsStayInRangeAndCarryNoGeometry() {
        for preset in PhotoPreset.builtIns {
            #expect((-3 ... 3).contains(preset.adjustments.exposure))
            #expect((-1 ... 1).contains(preset.adjustments.contrast))
            #expect((0 ... 1).contains(preset.adjustments.sharpness))
            #expect((0 ... 1).contains(preset.adjustments.vignette))
            #expect(preset.adjustments == preset.adjustments.lookOnly)
        }
    }
}
