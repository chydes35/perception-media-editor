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
}
