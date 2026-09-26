import Foundation

enum CheckFailure: Error {
    case failed(String)
}

@main
struct ModelCheck {
    static func main() throws {
        let assetID = UUID()
        let asset = MediaAsset(
            id: assetID,
            url: URL(fileURLWithPath: "/Volumes/Media/IMG_0001.CR3")
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
        let timelineClip = TimelineClip(assetID: assetID, durationSeconds: 12.5)
        let videoAdjustments = PhotoAdjustments(
            exposure: 0.35,
            contrast: 0.12,
            temperature: 0.08,
            vibrance: 0.16
        )
        let audioAdjustments = ClipAudioAdjustments(
            volume: 0.72,
            pan: -0.2,
            fadeInSeconds: 0.8,
            fadeOutSeconds: 1.1
        )
        let project = EditorProject(
            name: "Documentary",
            media: [asset],
            adjustmentsByAssetID: [assetID: adjustments],
            videoAdjustmentsByClipID: [timelineClip.id: videoAdjustments],
            audioAdjustmentsByClipID: [timelineClip.id: audioAdjustments],
            timelineClips: [timelineClip]
        )

        let document = ProjectDocument()
        let decoded = try document.project(from: document.data(for: project))

        try require(decoded.name == project.name, "Project name did not round-trip")
        try require(decoded.media.count == 1, "Referenced media count did not round-trip")
        try require(decoded.media.first?.id == asset.id, "Referenced media identity did not round-trip")
        try require(decoded.media.first?.url == asset.url, "Referenced media URL did not round-trip")
        try require(
            decoded.adjustmentsByAssetID[assetID] == adjustments,
            "Adjustments did not round-trip"
        )
        try require(decoded.timelineClips == [timelineClip], "Timeline clips did not round-trip")
        try require(
            decoded.videoAdjustmentsByClipID[timelineClip.id] == videoAdjustments,
            "Video adjustments did not round-trip"
        )
        try require(
            decoded.audioAdjustmentsByClipID[timelineClip.id] == audioAdjustments,
            "Audio adjustments did not round-trip"
        )

        let agentReport = AgentEngine.run(
            .photoCulling,
            project: project,
            selectedAssetID: assetID
        )
        try require(agentReport.kind == .photoCulling, "Photo culling agent returned the wrong report kind")
        let encodedAgentReport = try JSONEncoder().encode(agentReport)
        let decodedAgentReport = try JSONDecoder().decode(AgentReport.self, from: encodedAgentReport)
        try require(decodedAgentReport == agentReport, "Agent report did not round-trip")
        try require(
            decoded.schemaVersion == EditorProject.currentSchemaVersion,
            "Project was not saved with the current schema"
        )

        for preset in PhotoPreset.builtIns {
            try require((-3...3).contains(preset.adjustments.exposure), "Preset exposure is out of range")
            try require((-1...1).contains(preset.adjustments.contrast), "Preset contrast is out of range")
            try require((0...1).contains(preset.adjustments.sharpness), "Preset sharpness is out of range")
            try require((0...1).contains(preset.adjustments.vignette), "Preset vignette is out of range")
        }

        var schemaThreeObject = try JSONSerialization.jsonObject(with: document.data(for: project)) as! [String: Any]
        schemaThreeObject["schemaVersion"] = 3
        schemaThreeObject.removeValue(forKey: "audioAdjustmentsByClipID")
        let schemaThreeData = try JSONSerialization.data(withJSONObject: schemaThreeObject)
        let decodedSchemaThree = try document.project(from: schemaThreeData)
        try require(
            decodedSchemaThree.audioAdjustmentsByClipID.isEmpty,
            "Schema 3 projects did not default audio adjustments"
        )

        var schemaTwoObject = schemaThreeObject
        schemaTwoObject["schemaVersion"] = 2
        schemaTwoObject.removeValue(forKey: "videoAdjustmentsByClipID")
        let schemaTwoData = try JSONSerialization.data(withJSONObject: schemaTwoObject)
        let decodedSchemaTwo = try document.project(from: schemaTwoData)
        try require(
            decodedSchemaTwo.videoAdjustmentsByClipID.isEmpty,
            "Schema 2 projects did not default video adjustments"
        )

        let futureData = """
        {
          "schemaVersion": 999,
          "id": "00000000-0000-0000-0000-000000000001",
          "name": "Future Project",
          "createdAt": "2026-09-25T12:00:00Z",
          "updatedAt": "2026-09-25T12:00:00Z",
          "media": [],
          "adjustmentsByAssetID": []
        }
        """.data(using: .utf8)!

        do {
            _ = try document.project(from: futureData)
            throw CheckFailure.failed("Future project schema was accepted")
        } catch is ProjectDocumentError {
            // Expected.
        }

        print("Model checks passed")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw CheckFailure.failed(message) }
    }
}
