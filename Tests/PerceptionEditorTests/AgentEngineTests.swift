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

struct LookMatchReportTests {
    @Test func reportListsProposalsAndFindingsPerScene() {
        let assets = (1 ... 6).map { MediaAsset(url: URL(fileURLWithPath: "/Volumes/Shoot/P\($0).RW2")) }
        let ids = assets.map(\.id)
        let project = EditorProject(name: "Shoot", media: assets)
        let result = LookMatchResult(scenes: [
            LookMatchScene(index: 1, assetIDs: Array(ids[0 ... 3]), heroID: ids[0],
                           proposals: [
                               LookMatchProposal(targetID: ids[1], heroID: ids[0], adjustments: .neutral,
                                                 confidence: 0.9, isFlagged: false),
                               LookMatchProposal(targetID: ids[2], heroID: ids[0], adjustments: .neutral,
                                                 confidence: 0.4, isFlagged: true)
                           ],
                           alreadyEdited: [ids[3]]),
            LookMatchScene(index: 2, assetIDs: Array(ids[4 ... 5]), suggestedHeroID: ids[5])
        ])
        let report = AgentEngine.lookMatchReport(result, project: project, thresholds: .default, startedAt: .now)

        #expect(report.kind == .lookMatching)
        #expect(report.proposedChanges.map(\.targetAssetID) == [ids[1], ids[2]])
        #expect(report.proposedChanges.map(\.isSelected) == [true, false])
        #expect(report.proposedChanges.allSatisfy { $0.kind == .matchLook && $0.sourceAssetID == ids[0] && $0.sceneIndex == 1 })
        let needsHero = report.findings.first { $0.title == "Scene 2 needs a hero" }
        #expect(needsHero?.assetID == ids[5])
        #expect(needsHero?.detail.contains("P6.RW2") == true)
        #expect(report.findings.contains { $0.title == "Already edited" && $0.assetID == ids[3] })
        #expect(report.findings.contains { $0.title == "1 low-confidence match" })
        #expect(report.summary == "Found 2 scenes in 6 photos and prepared 2 proposals from 1 hero (1 flagged).")
    }

    @Test func engineRunForLookMatchingOnlyReportsPreconditions() {
        let assets = (1 ... 2).map { MediaAsset(url: URL(fileURLWithPath: "/Volumes/Shoot/P\($0).RW2")) }
        let project = EditorProject(name: "Shoot", media: assets)
        let report = AgentEngine.run(.lookMatching, project: project, selectedAssetID: assets[0].id)
        #expect(report.proposedChanges.isEmpty)
        #expect(report.findings.first?.title == "No edited hero photo")
    }
}
