import CoreImage
import Foundation
import Testing
@testable import PerceptionEditor

struct GroupRecoveryTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PME_GROUP_PROBE_INPUT"] != nil))
    func missedSmallPeopleAreEditableAndPickable() throws {
        let path = try #require(ProcessInfo.processInfo.environment["PME_GROUP_PROBE_INPUT"])
        if let output = ProcessInfo.processInfo.environment["PME_GROUP_QA_PROJECT_OUTPUT"] {
            var project = EditorProject.starter
            project.media = [MediaAsset(url: URL(fileURLWithPath: path), pixelWidth: 6000, pixelHeight: 4000)]
            try ProjectDocument().data(for: project).write(to: URL(fileURLWithPath: output), options: .atomic)
        }
        let analysis = try SubjectAnalyzer.analyze(url: URL(fileURLWithPath: path))
        let girl = try #require(analysis.candidate(at: NormalizedPoint(x: 0.243, y: 0.52)))
        let boy = try #require(analysis.candidate(at: NormalizedPoint(x: 0.865, y: 0.50)))
        #expect(girl.kind == .group && boy.kind == .group)
        #expect(girl.id != boy.id)
        let child = try #require(analysis.candidate(at: NormalizedPoint(x: 0.976, y: 0.75)))
        #expect(child.kind == .person)
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        func weight(_ png: Data, _ x: Double, _ y: Double) throws -> UInt8 {
            let image = try #require(CIImage(data: png, options: [.colorSpace: NSNull()]))
            var pixel: UInt8 = 0
            context.render(image, toBitmap: &pixel, rowBytes: 1,
                           bounds: CGRect(x: x * image.extent.width, y: (1 - y) * image.extent.height, width: 1, height: 1),
                           format: .L8, colorSpace: nil)
            return pixel
        }
        #expect(try weight(girl.png, 0.243, 0.52) > 150)
        #expect(try weight(boy.png, 0.865, 0.50) > 150)
        #expect(try weight(girl.png, 0.865, 0.50) < 50)
        #expect(try weight(boy.png, 0.243, 0.52) < 50)
        for point in [NormalizedPoint(x: 0.5, y: 0.1), NormalizedPoint(x: 0.5, y: 0.8)] {
            #expect(try weight(analysis.allSubjectsPNG, point.x, point.y) < 50)
            #expect(analysis.candidate(at: point) == nil)
        }
    }

    @Test func supplementalPickingUsesOfferedMaskBeforeCoarseNativeLabels() {
        let native = SubjectCandidate(id: 1, kind: .person, png: Data(), pixelCount: 1)
        let recovered = SubjectCandidate(id: 513, kind: .group, png: Data(), pixelCount: 1)
        let analysis = SubjectAnalysis(candidates: [native, recovered], allSubjectsPNG: Data(),
                                       personLabels: SubjectLabelMap(data: Data([1, 1]), width: 2, height: 1),
                                       foregroundLabels: nil,
                                       supplementalLabels: SubjectLabelMap(data: Data([1, 0]), width: 2, height: 1))
        #expect(analysis.candidate(at: NormalizedPoint(x: 0.25, y: 0.5))?.id == recovered.id)
        #expect(analysis.candidate(at: NormalizedPoint(x: 0.75, y: 0.5))?.id == native.id)
        #expect(analysis.candidate(at: NormalizedPoint(x: -0.1, y: 0.5)) == nil)
    }
}
