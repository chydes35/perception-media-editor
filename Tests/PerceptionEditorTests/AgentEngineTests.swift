import Foundation
import Testing
@testable import PerceptionEditor

struct AgentEngineTests {
    private func photo(_ name: String, width: Int?, height: Int?) -> MediaAsset {
        MediaAsset(
            url: URL(fileURLWithPath: "/Volumes/Shoot/\(name)"),
            pixelWidth: width,
            pixelHeight: height
        )
    }

    @Test func cullingOnlyFlagsKnownLowResolutionPhotos() {
        let full = photo("P1.RW2", width: 6000, height: 4000)
        let small = photo("P2.JPG", width: 1080, height: 720)
        let unknown = photo("P3.RW2", width: nil, height: nil)
        let project = EditorProject(name: "Shoot", media: [full, small, unknown])

        let report = AgentEngine.run(.photoCulling, project: project, selectedAssetID: nil)
        let lowResolution = report.findings.filter { $0.title == "Low-resolution source" }

        #expect(lowResolution.map(\.assetID) == [small.id])
    }

    @Test func reportsRoundTripThroughJSON() throws {
        let project = EditorProject(name: "Shoot", media: [photo("P1.RW2", width: 6000, height: 4000)])
        let report = AgentEngine.run(.photoCulling, project: project, selectedAssetID: nil)
        let decoded = try JSONDecoder().decode(AgentReport.self, from: JSONEncoder().encode(report))
        #expect(decoded == report)
    }

    @Test func lookMatchChangesRoundTripThroughJSON() throws {
        var adjustments = PhotoAdjustments.neutral
        adjustments.exposure = 0.7
        adjustments.raw.temperature = 5200
        let report = AgentReport(
            kind: .lookMatching, startedAt: .now, summary: "Look Match", findings: [],
            proposedChanges: [AgentChange(kind: .matchLook, sourceAssetID: UUID(), targetAssetID: UUID(),
                                          detail: "Match", proposedAdjustments: adjustments,
                                          confidence: 0.42, sceneIndex: 3, isSelected: false)]
        )
        let decoded = try JSONDecoder().decode(AgentReport.self, from: JSONEncoder().encode(report))
        #expect(decoded == report)
        #expect(decoded.proposedChanges[0].proposedAdjustments?.exposure == 0.7)
        #expect(decoded.proposedChanges[0].isSelected == false)
    }

    /// A report saved before Look Match proposals existed.
    @Test func reportsWithoutLookMatchFieldsStillDecode() throws {
        let json = """
        {"id":"6F1C2B9E-6A55-4C1F-9C7B-2D1D2F9E8A01","kind":"Look Matching","startedAt":0,"finishedAt":1,
         "summary":"Prepared a look-match proposal","findings":[],"limitation":null,
         "proposedChanges":[{"id":"0A5B7C2E-1111-4C1F-9C7B-2D1D2F9E8A02","kind":"copyPhotoAdjustments",
           "sourceAssetID":"0A5B7C2E-2222-4C1F-9C7B-2D1D2F9E8A03","targetAssetID":"0A5B7C2E-3333-4C1F-9C7B-2D1D2F9E8A04",
           "detail":"Copy the look"}]}
        """
        let report = try JSONDecoder().decode(AgentReport.self, from: Data(json.utf8))
        let change = try #require(report.proposedChanges.first)
        #expect(change.kind == .copyPhotoAdjustments)
        #expect(change.proposedAdjustments == nil)
        #expect(change.confidence == nil)
        #expect(change.sceneIndex == nil)
        #expect(change.isSelected)
    }
}
