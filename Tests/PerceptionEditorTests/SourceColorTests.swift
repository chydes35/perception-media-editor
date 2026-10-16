@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import PerceptionEditor

struct SourceColorTests {
    /// Trimmed from P1107158.MOV (Lumix S5, V-Log).
    static let vLogXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="no" ?>
    <ClipMain xmlns="urn:schemas-Professional-Plug-in:Semi-Pro:ClipMetadata:v1.0">
      <ClipContent>
        <EditUnit>1001/24000</EditUnit>
        <EssenceList><Video><Codec BitRate="150">H264_422_LongGOP</Codec><BitDepth>10</BitDepth></Video></EssenceList>
      </ClipContent>
      <UserArea>
        <AcquisitionMetadata xmlns="urn:schemas-Professional-Plug-in:P2:CameraMetadata:v1.2">
          <CameraUnitMetadata>
            <Gamma><CaptureGamma>V-Log</CaptureGamma></Gamma>
            <Gamut><CaptureGamut>V-Gamut</CaptureGamut></Gamut>
          </CameraUnitMetadata>
        </AcquisitionMetadata>
      </UserArea>
    </ClipMain>
    """

    /// Trimmed from P1107172.MOV (Lumix S5, standard gamma, 8-bit).
    static let standardXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="no" ?>
    <ClipMain xmlns="urn:schemas-Professional-Plug-in:Semi-Pro:ClipMetadata:v1.0">
      <ClipContent><EssenceList><Video><BitDepth>8</BitDepth></Video></EssenceList></ClipContent>
      <UserArea><AcquisitionMetadata><CameraUnitMetadata>
        <Gamma><CaptureGamma>STANDARD</CaptureGamma></Gamma>
        <Gamut><CaptureGamut>BT.709</CaptureGamut></Gamut>
      </CameraUnitMetadata></AcquisitionMetadata></UserArea>
    </ClipMain>
    """

    /// The `avcC` header and the first 16 bytes of the SPS each camera file carries (no PPS).
    static let vLogAVCC = Data(hex: "017a0033ffe10010" + "677a0033b6cb401e0021f6028c040405" + "00")
    static let standardAVCC = Data(hex: "01640033ffe10010" + "67640033acec03c0043ffc05a808080a" + "00")

    private func format(
        codec: CMVideoCodecType = kCMVideoCodecType_H264,
        fullRange: Bool?,
        primaries: CFString? = kCMFormatDescriptionColorPrimaries_ITU_R_709_2,
        transfer: CFString? = kCMFormatDescriptionTransferFunction_ITU_R_709_2,
        matrix: CFString? = kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2,
        atoms: [String: Data] = [:]
    ) throws -> CMFormatDescription {
        var extensions: [String: Any] = [:]
        if let fullRange { extensions[kCMFormatDescriptionExtension_FullRangeVideo as String] = fullRange }
        if let primaries { extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] = primaries }
        if let transfer { extensions[kCMFormatDescriptionExtension_TransferFunction as String] = transfer }
        if let matrix { extensions[kCMFormatDescriptionExtension_YCbCrMatrix as String] = matrix }
        if !atoms.isEmpty { extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] = atoms }
        var description: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: nil, codecType: codec, width: 3840, height: 2160,
            extensions: extensions as CFDictionary, formatDescriptionOut: &description
        )
        try #require(status == noErr)
        return try #require(description)
    }

    @Test func panasonicMetadataNamesTheRealGammaAndGamut() throws {
        let capture = try #require(PanasonicClipMetadata(xml: Self.vLogXML))
        #expect(capture.captureGamma == "V-Log" && capture.captureGamut == "V-Gamut" && capture.bitDepth == 10)
        let standard = try #require(PanasonicClipMetadata(xml: Self.standardXML))
        #expect(standard.captureGamma == "STANDARD" && standard.bitDepth == 8)
    }

    @Test func malformedOrUnrelatedXMLIsIgnored() {
        #expect(PanasonicClipMetadata(xml: "<ClipMain><Gamma><CaptureGamma>V-Log") == nil)
        #expect(PanasonicClipMetadata(xml: "not xml at all") == nil)
        #expect(PanasonicClipMetadata(xml: "<?xml version=\"1.0\"?><Other><Thing>1</Thing></Other>") == nil)
    }

    /// The S5 tags V-Log as BT.709; the camera's own metadata wins over those tags.
    @Test func vLogFromCameraMetadataOverridesTheBT709Tags() throws {
        let descriptor = SourceColorDetector.descriptor(
            format: try format(fullRange: true, atoms: ["avcC": Self.vLogAVCC]),
            panasonicXML: Self.vLogXML
        )
        #expect(descriptor.transfer == .vLog && descriptor.gamut == .vGamut)
        #expect(descriptor.range == .full && descriptor.matrix == .rec709)
        #expect(descriptor.bitDepth == 10 && descriptor.chroma == .yuv422)
        #expect(descriptor.detectedFrom == .panasonicMetadata)
        #expect(descriptor.isLog)
        #expect(descriptor.summary == "V-Log / V-Gamut (camera metadata), 10-bit 4:2:2, full range")
    }

    @Test func standardPanasonicClipsFollowTheirTags() throws {
        let descriptor = SourceColorDetector.descriptor(
            format: try format(fullRange: false, atoms: ["avcC": Self.standardAVCC]),
            panasonicXML: Self.standardXML
        )
        #expect(descriptor.transfer == .rec709 && descriptor.gamut == .rec709 && !descriptor.isLog)
        #expect(descriptor.range == .video && descriptor.bitDepth == 8 && descriptor.chroma == .yuv420)
        #expect(descriptor.detectedFrom == .panasonicMetadata)
    }

    @Test func withoutCameraMetadataTheTagsDecide() throws {
        let tagged = SourceColorDetector.descriptor(format: try format(fullRange: nil), panasonicXML: nil)
        #expect(tagged.transfer == .rec709 && tagged.gamut == .rec709 && tagged.range == .video)
        #expect(tagged.detectedFrom == .formatDescription && tagged.bitDepth == nil)

        let malformed = SourceColorDetector.descriptor(format: try format(fullRange: true), panasonicXML: "<broken")
        #expect(malformed.detectedFrom == .formatDescription && malformed.transfer == .rec709 && malformed.range == .full)

        let untagged = SourceColorDetector.descriptor(
            format: try format(fullRange: nil, primaries: nil, transfer: nil, matrix: nil), panasonicXML: nil
        )
        #expect(untagged.transfer == .unknown && untagged.gamut == .unknown && untagged.matrix == .unknown)
    }

    @Test func otherMatricesAndTransfersAreNotTakenForRec709() throws {
        let hlg = SourceColorDetector.descriptor(
            format: try format(
                fullRange: false,
                primaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
                transfer: kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG,
                matrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
            ),
            panasonicXML: nil
        )
        #expect(hlg.transfer == .unknown && hlg.gamut == .unknown && hlg.matrix == .rec2020)
        let sd = SourceColorDetector.descriptor(
            format: try format(fullRange: false, matrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4), panasonicXML: nil
        )
        #expect(sd.matrix == .rec601)
    }

    @Test func codecConfigurationGivesBitDepthAndChroma() throws {
        #expect(SourceColorDetector.codedFormat(try format(fullRange: true, atoms: ["avcC": Self.vLogAVCC])) == CodedVideoFormat(bitDepth: 10, chroma: .yuv422))
        #expect(SourceColorDetector.codedFormat(try format(fullRange: false, atoms: ["avcC": Self.standardAVCC])) == CodedVideoFormat(bitDepth: 8, chroma: .yuv420))
        // ProRes 422 HQ is always 10-bit 4:2:2.
        #expect(SourceColorDetector.codedFormat(try format(codec: kCMVideoCodecType_AppleProRes422HQ, fullRange: false)) == CodedVideoFormat(bitDepth: 10, chroma: .yuv422))
        // A truncated avcC tells nothing rather than something wrong.
        #expect(SourceColorDetector.codedFormat(try format(fullRange: false, atoms: ["avcC": Data([0x01, 0x7a])])) == CodedVideoFormat(bitDepth: nil, chroma: nil))
    }

    @Test func colorInputRoundTripsAndDefaultsToAutomatic() throws {
        let document = ProjectDocument()
        let asset = MediaAsset(url: URL(fileURLWithPath: "/Volumes/Card/P1107158.MOV"), kind: .video)
        var project = EditorProject(name: "Color", media: [asset])
        #expect(project.colorInput(for: asset.id) == .automatic)
        project.colorInputByAssetID[asset.id] = ColorInputTransform.none
        project.media[0].sourceColor = SourceColorDetector.descriptor(
            format: try format(fullRange: true, atoms: ["avcC": Self.vLogAVCC]), panasonicXML: Self.vLogXML
        )
        let decoded = try document.project(from: document.data(for: project))
        #expect(decoded.colorInput(for: asset.id) == ColorInputTransform.none)
        #expect(decoded.media[0].sourceColor == project.media[0].sourceColor)
    }
}

extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index ..< next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}
