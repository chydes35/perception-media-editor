import CoreImage
import Foundation
import Testing
@testable import PerceptionEditor

struct GradingGrainTests {
    private func render(_ adjustments: PhotoAdjustments, gray: Double, size: Int = 96) -> [UInt8] {
        let source = CIImage(color: CIColor(red: gray, green: gray, blue: gray)).cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
        let output = MediaColorRenderer.render(source, adjustments: adjustments, includesGeometry: true)
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        context.render(output, toBitmap: &bytes, rowBytes: size * 4, bounds: CGRect(x: 0, y: 0, width: size, height: size),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return bytes
    }

    private func channelMeans(_ bytes: [UInt8]) -> (r: Double, g: Double, b: Double) {
        var sums = (0.0, 0.0, 0.0)
        let pixels = bytes.count / 4
        for i in 0 ..< pixels {
            sums.0 += Double(bytes[i * 4]); sums.1 += Double(bytes[i * 4 + 1]); sums.2 += Double(bytes[i * 4 + 2])
        }
        return (sums.0 / Double(pixels), sums.1 / Double(pixels), sums.2 / Double(pixels))
    }

    @Test func neutralGradeLeavesColorsAlone() {
        let c = ColorGradeMath.apply(ColorGradeAdjustments(), r: 0.3, g: 0.5, b: 0.7)
        #expect(abs(c.r - 0.3) < 1e-9 && abs(c.g - 0.5) < 1e-9 && abs(c.b - 0.7) < 1e-9)
    }

    @Test func shadowTintAffectsShadowsMoreThanHighlights() {
        var grade = ColorGradeAdjustments()
        grade.shadows = GradeZone(hue: 240, saturation: 1, luminance: 0)
        let dark = ColorGradeMath.apply(grade, r: 0.1, g: 0.1, b: 0.1)
        let bright = ColorGradeMath.apply(grade, r: 0.9, g: 0.9, b: 0.9)
        #expect(dark.b - dark.r > 0.1, "a blue shadow tint makes dark grays bluer")
        #expect(abs(bright.b - bright.r) < 0.02, "and leaves bright grays alone")
    }

    @Test func balanceMovesTheBoundary() {
        var grade = ColorGradeAdjustments()
        let neutral = ColorGradeMath.weights(grade, lightness: 0.5)
        grade.balance = 1
        let moved = ColorGradeMath.weights(grade, lightness: 0.5)
        #expect(moved.highlights > neutral.highlights)
    }

    @Test func gradeAndGrainSurviveCoding() throws {
        var a = PhotoAdjustments()
        a.grading = ColorGradeAdjustments(shadows: GradeZone(hue: 200, saturation: 0.4, luminance: -0.1))
        a.grain = GrainAdjustments(amount: 0.4, size: 0.3, roughness: 0.6)
        let decoded = try JSONDecoder().decode(PhotoAdjustments.self, from: JSONEncoder().encode(a))
        #expect(decoded == a)
        let old = try JSONDecoder().decode(PhotoAdjustments.self, from: Data("{}".utf8))
        #expect(old.grading == nil && old.grain == nil)
    }

    @Test func newGroupsCarryOnlyTheirOwnSettings() {
        var source = PhotoAdjustments()
        source.grading = ColorGradeAdjustments(highlights: GradeZone(hue: 40, saturation: 0.5, luminance: 0))
        source.grain = GrainAdjustments(amount: 0.5)
        let onlyGrain = PhotoAdjustments().applying(source, groups: [.grain])
        #expect(onlyGrain.grain == source.grain && onlyGrain.grading == nil)
        let onlyGrade = PhotoAdjustments().applying(source, groups: [.colorGrading])
        #expect(onlyGrade.grading == source.grading && onlyGrade.grain == nil)
        #expect(source.editedGroups == [.colorGrading, .grain])
    }

    @Test func gradeAndGrainBlendWithPresetAmount() throws {
        var source = PhotoAdjustments()
        source.grading = ColorGradeAdjustments(shadows: GradeZone(hue: 220, saturation: 0.8, luminance: 0))
        source.grain = GrainAdjustments(amount: 0.6)
        let half = PhotoAdjustments().applying(source, groups: [.colorGrading, .grain], amount: 0.5)
        #expect(abs((half.grading?.shadows.saturation ?? 0) - 0.4) < 1e-9)
        #expect(half.grading?.shadows.hue == 220)
        #expect(abs((half.grain?.amount ?? 0) - 0.3) < 1e-9)
    }

    @Test func renderingAGradeTintsShadows() {
        var adjustments = PhotoAdjustments()
        adjustments.grading = ColorGradeAdjustments(shadows: GradeZone(hue: 240, saturation: 1, luminance: 0))
        let means = channelMeans(render(adjustments, gray: 0.15))
        #expect(means.b - means.r > 10)
    }

    @Test func grainAddsStableNoiseAndNeutralAddsNone() {
        let flat = render(PhotoAdjustments(), gray: 0.5)
        #expect(Set(flat).count <= 3, "an untouched flat image stays flat")

        var adjustments = PhotoAdjustments()
        adjustments.grain = GrainAdjustments(amount: 0.8)
        let first = render(adjustments, gray: 0.5)
        let second = render(adjustments, gray: 0.5)
        #expect(first == second, "the grain pattern is the same every render")
        #expect(Set(first).count > 10, "grain varies the pixels")
    }

    @Test func importerMapsGradingAndGrain() throws {
        let xml = #"""
        <x:xmpmeta xmlns:x="a"><rdf:RDF xmlns:rdf="r"><rdf:Description xmlns:crs="c" crs:Name="G"
          crs:ColorGradeShadowHue="230" crs:ColorGradeShadowSat="8" crs:ColorGradeShadowLum="-10"
          crs:ColorGradeHighlightHue="50" crs:ColorGradeHighlightSat="5" crs:ColorGradeBlending="70" crs:ColorGradeBalance="-20"
          crs:GrainAmount="24.3" crs:GrainSize="19.5" crs:GrainFrequency="40"/></rdf:RDF></x:xmpmeta>
        """#
        let result = try LightroomPresetImporter.importPreset(from: Data(xml.utf8), fallbackName: "f")
        let grade = try #require(result.preset.adjustments.grading)
        #expect(grade.shadows.hue == 230 && abs(grade.shadows.saturation - 0.08) < 1e-9 && abs(grade.shadows.luminance + 0.1) < 1e-9)
        #expect(grade.highlights.hue == 50 && grade.blending == 0.7 && abs(grade.balance + 0.2) < 1e-9)
        let grain = try #require(result.preset.adjustments.grain)
        #expect(abs(grain.amount - 0.243) < 1e-9 && abs(grain.size - 0.195) < 1e-9 && abs(grain.roughness - 0.4) < 1e-9)
        #expect(result.preset.effectiveGroups == [.colorGrading, .grain])
        #expect(!result.unsupported.contains { $0.hasPrefix("ColorGrade") || $0.hasPrefix("Grain") })
    }

    @Test func importerFallsBackToSplitToning() throws {
        let xml = #"<x:xmpmeta xmlns:x="a"><rdf:RDF xmlns:rdf="r"><rdf:Description xmlns:crs="c" crs:SplitToningShadowHue="220" crs:SplitToningShadowSaturation="30" crs:SplitToningHighlightHue="40" crs:SplitToningHighlightSaturation="20" crs:SplitToningBalance="10"/></rdf:RDF></x:xmpmeta>"#
        let preset = try LightroomPresetImporter.importPreset(from: Data(xml.utf8), fallbackName: "s").preset
        let grade = try #require(preset.adjustments.grading)
        #expect(grade.shadows.hue == 220 && abs(grade.shadows.saturation - 0.3) < 1e-9)
        #expect(abs(grade.highlights.saturation - 0.2) < 1e-9 && abs(grade.balance - 0.1) < 1e-9)
    }
}

extension ColorGradeAdjustments {
    fileprivate init(shadows: GradeZone = GradeZone(), highlights: GradeZone = GradeZone()) {
        self.init()
        self.shadows = shadows
        self.highlights = highlights
    }
}
