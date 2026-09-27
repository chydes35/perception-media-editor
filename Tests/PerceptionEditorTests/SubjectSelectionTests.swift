import CoreImage
import Foundation
import Testing
@testable import PerceptionEditor

struct SubjectSelectionTests {
    @Test func subjectMasksAndBrushCorrectionsSurviveProjectSave() throws {
        let subject = SubjectMask(
            png: Data([1, 2, 3, 4]),
            strokes: [BrushStroke(
                points: [NormalizedPoint(x: 0.2, y: 0.3)],
                size: 0.04, feather: 0.5, isErase: true
            )]
        )
        let asset = MediaAsset(url: URL(fileURLWithPath: "/tmp/subject.jpg"))
        var project = EditorProject.starter
        project.media = [asset]
        var adjustments = PhotoAdjustments()
        adjustments.masks = [LocalMask(shape: .subject(subject))]
        project.adjustmentsByAssetID[asset.id] = adjustments

        let decoded = try ProjectDocument().project(from: ProjectDocument().data(for: project))
        #expect(decoded.schemaVersion == 8)
        #expect(decoded.adjustmentsByAssetID[asset.id]?.masks == adjustments.masks)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PERCEPTION_TWO_PERSON_TEST_PHOTO"] != nil))
    func twoPeopleStaySeparateAndMasksAlignWithThePhoto() throws {
        let path = try #require(ProcessInfo.processInfo.environment["PERCEPTION_TWO_PERSON_TEST_PHOTO"])
        let analysis = try SubjectAnalyzer.analyze(url: URL(fileURLWithPath: path))
        let left = try #require(analysis.candidate(at: NormalizedPoint(x: 0.36, y: 0.52)))
        let right = try #require(analysis.candidate(at: NormalizedPoint(x: 0.62, y: 0.52)))
        #expect(left.id != right.id)
        #expect(left.name.hasPrefix("Person"))
        #expect(right.name.hasPrefix("Person"))
        #expect(analysis.candidates.count >= 2)
        if let output = ProcessInfo.processInfo.environment["PERCEPTION_SUBJECT_MASK_OUTPUT"] {
            try left.png.write(to: URL(fileURLWithPath: output), options: .atomic)
        }

        let image = SubjectMaskRenderer.image(
            SubjectMask(png: left.png),
            extent: CGRect(x: 0, y: 0, width: 1536, height: 2048)
        )
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        func weight(_ image: CIImage, _ x: Double, _ y: Double) -> UInt8 {
            var pixel = [UInt8](repeating: 0, count: 4)
            context.render(
                image, toBitmap: &pixel, rowBytes: 4,
                bounds: CGRect(x: x * 1536, y: (1 - y) * 2048, width: 1, height: 1),
                format: .RGBA8, colorSpace: nil
            )
            return pixel[0]
        }
        #expect(weight(image, 0.36, 0.52) > 150)
        #expect(weight(image, 0.62, 0.52) < 100)
        #expect(weight(image, 0.5, 0.1) < 50)

        var refined = SubjectMask(png: left.png)
        let center = NormalizedPoint(x: 0.36, y: 0.52)
        refined.strokes.append(BrushStroke(points: [center], size: 0.08, feather: 0.2, isErase: true))
        let erased = SubjectMaskRenderer.image(refined, extent: image.extent)
        #expect(weight(erased, 0.36, 0.52) < 50)
        refined.strokes.append(BrushStroke(points: [center], size: 0.08, feather: 0.2))
        let restored = SubjectMaskRenderer.image(refined, extent: image.extent)
        #expect(weight(restored, 0.36, 0.52) > 150)
    }
}
