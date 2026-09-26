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
            cropAspect: .portrait
        )
        let project = EditorProject(
            name: "Documentary",
            media: [asset],
            adjustmentsByAssetID: [assetID: adjustments]
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

        for preset in PhotoPreset.builtIns {
            try require((-3...3).contains(preset.adjustments.exposure), "Preset exposure is out of range")
            try require((-1...1).contains(preset.adjustments.contrast), "Preset contrast is out of range")
            try require((0...1).contains(preset.adjustments.sharpness), "Preset sharpness is out of range")
            try require((0...1).contains(preset.adjustments.vignette), "Preset vignette is out of range")
        }

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
