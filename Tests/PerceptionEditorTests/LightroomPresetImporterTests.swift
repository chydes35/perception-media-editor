import Foundation
import Testing
@testable import PerceptionEditor

struct LightroomPresetImporterTests {
    private let xmp = """
    <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
     <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
       crs:Contrast2012="+40" crs:Highlights2012="-60" crs:Shadows2012="+20" crs:Clarity2012="+10"
       crs:Vibrance="+17" crs:Sharpness="75" crs:PostCropVignetteAmount="-30"
       crs:HueAdjustmentOrange="+10" crs:SaturationAdjustmentBlue="-50" crs:LuminanceSmoothing="25"
       crs:Temperature="4554" crs:WhiteBalance="Custom">
      <crs:Name><rdf:Alt><rdf:li xml:lang="x-default">Storm</rdf:li></rdf:Alt></crs:Name>
      <crs:Group><rdf:Alt><rdf:li xml:lang="x-default">Pete M V4</rdf:li></rdf:Alt></crs:Group>
      <crs:ToneCurvePV2012><rdf:Seq>
       <rdf:li>1, 0</rdf:li><rdf:li>60, 40</rdf:li><rdf:li>123, 93</rdf:li><rdf:li>255, 255</rdf:li>
      </rdf:Seq></crs:ToneCurvePV2012>
      <crs:ToneCurvePV2012Red><rdf:Seq><rdf:li>0, 0</rdf:li><rdf:li>255, 255</rdf:li></rdf:Seq></crs:ToneCurvePV2012Red>
     </rdf:Description></rdf:RDF></x:xmpmeta>
    """

    @Test func mapsSupportedSettingsAndScalesThem() throws {
        let result = try LightroomPresetImporter.importPreset(from: Data(xmp.utf8), fallbackName: "file")
        let preset = result.preset
        #expect(preset.name == "Storm")
        #expect(preset.category == "Pete M V4")
        #expect(preset.adjustments.contrast == 0.4)
        #expect(preset.adjustments.highlights == -0.6)
        #expect(preset.adjustments.vibrance == 0.17)
        #expect(preset.adjustments.sharpness == 0.5)
        #expect(preset.adjustments.vignette == 0.3)
        #expect(preset.adjustments.hsl?.orange.hue == 0.1)
        #expect(preset.adjustments.hsl?.blue.saturation == -0.5)
        #expect(preset.adjustments.raw.luminanceNoiseReduction == 0.25)
        #expect(preset.effectiveGroups == [.tone, .color, .presence, .toneCurve, .hsl, .rawDetail])
    }

    @Test func curveStartsAtZeroAndLinearChannelsAreDropped() throws {
        let preset = try LightroomPresetImporter.importPreset(from: Data(xmp.utf8), fallbackName: "file").preset
        let curve = try #require(preset.adjustments.curves.rgb)
        #expect(curve.points.first?.x == 0)
        #expect(curve.points.last?.x == 1)
        #expect(preset.adjustments.curves.red == nil)
    }

    @Test func reportsWhatItCouldNotImport() throws {
        let result = try LightroomPresetImporter.importPreset(from: Data(xmp.utf8), fallbackName: "file")
        #expect(result.unsupported.contains("Clarity2012"))
        #expect(result.unsupported.contains("WhiteBalance"))
        #expect(!result.unsupported.contains("Contrast2012"))
    }

    @Test func fallsBackToFileNameAndRejectsNonPresets() throws {
        let bare = #"<x:xmpmeta xmlns:x="a"><rdf:RDF xmlns:rdf="r"><rdf:Description xmlns:crs="c" crs:Contrast2012="+5"/></rdf:RDF></x:xmpmeta>"#
        let result = try LightroomPresetImporter.importPreset(from: Data(bare.utf8), fallbackName: "Mine")
        #expect(result.preset.name == "Mine")
        #expect(result.preset.category == "Imported")
        #expect(throws: (any Error).self) {
            try LightroomPresetImporter.importPreset(from: Data("not xml".utf8), fallbackName: "x")
        }
    }
}

extension LightroomPresetImporterTests {
    @Test func lookWithOnlyAColorTableIsRejectedWithAClearReason() {
        let lut = #"<x:xmpmeta xmlns:x="a"><rdf:RDF xmlns:rdf="r"><rdf:Description xmlns:crs="c" crs:RGBTable="ABC" crs:Table_ABC="xyz"/></rdf:RDF></x:xmpmeta>"#
        #expect(throws: LightroomPresetImporter.ImportError.colorTableOnly) {
            try LightroomPresetImporter.importPreset(from: Data(lut.utf8), fallbackName: "x")
        }
    }
}

extension LightroomPresetImporterTests {
    @Test func nestedLookDescriptionDoesNotOverwriteThePresetName() throws {
        let xml = """
        <x:xmpmeta xmlns:x="a"><rdf:RDF xmlns:rdf="r"><rdf:Description xmlns:crs="c" crs:Name="06 Ilford HP5" crs:Contrast2012="-7.5" crs:Treatment="Monochrome">
         <crs:Group><rdf:Alt><rdf:li>Black White</rdf:li></rdf:Alt></crs:Group>
         <crs:Look><rdf:Description crs:Name="Adobe Monochrome" crs:Amount="1.0"><crs:Group><rdf:Alt><rdf:li>Profiles</rdf:li></rdf:Alt></crs:Group></rdf:Description></crs:Look>
        </rdf:Description></rdf:RDF></x:xmpmeta>
        """
        let preset = try LightroomPresetImporter.importPreset(from: Data(xml.utf8), fallbackName: "f").preset
        #expect(preset.name == "Ilford HP5")
        #expect(preset.category == "Black White")
        #expect(preset.adjustments.contrast == -0.075)
    }
}
