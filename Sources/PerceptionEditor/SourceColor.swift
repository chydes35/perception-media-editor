@preconcurrency import AVFoundation
import Foundation

enum YCbCrRange: String, Codable, Sendable { case video, full }
enum YCbCrMatrix: String, Codable, Sendable { case rec709, rec601, rec2020, unknown }
enum ChromaSubsampling: String, Codable, Sendable {
    case yuv420 = "4:2:0", yuv422 = "4:2:2", yuv444 = "4:4:4"
}
/// Only what the pipeline renders. Anything else (HLG, PQ, other camera logs) is `.unknown`.
enum SourceTransfer: String, Codable, Sendable { case rec709, vLog, unknown }
enum SourceGamut: String, Codable, Sendable { case rec709, vGamut, unknown }
enum SourceColorEvidence: String, Codable, Sendable {
    /// The camera's own clip metadata (Panasonic `CaptureGamma`/`CaptureGamut`).
    case panasonicMetadata = "panasonic-xml"
    /// The container's color tags, which the S5 sets to BT.709 even for V-Log.
    case formatDescription = "format-description"
}

/// What a video file's code values mean. Detected from the original (never from a proxy) on import,
/// and backfilled when an older project opens (schema 11).
struct SourceColorDescriptor: Codable, Hashable, Sendable {
    var bitDepth: Int?
    var chroma: ChromaSubsampling?
    var range: YCbCrRange
    var matrix: YCbCrMatrix
    var transfer: SourceTransfer
    var gamut: SourceGamut
    var detectedFrom: SourceColorEvidence

    var isLog: Bool { transfer == .vLog }

    /// For the inspector, e.g. "V-Log / V-Gamut (camera metadata), 10-bit 4:2:2, full range".
    var summary: String {
        let curve: String = switch (transfer, gamut) {
        case (.vLog, .vGamut): "V-Log / V-Gamut"
        case (.vLog, _): "V-Log"
        case (.rec709, _): "Rec. 709"
        case (.unknown, _): "Unknown color"
        }
        let source = detectedFrom == .panasonicMetadata ? " (camera metadata)" : ""
        let format = [bitDepth.map { "\($0)-bit" }, chroma?.rawValue].compactMap { $0 }.joined(separator: " ")
        let rangeText = range == .full ? "full range" : "video range"
        return "\(curve)\(source), " + (format.isEmpty ? rangeText : "\(format), \(rangeText)")
    }
}

/// How a source's code values become picture color. Set per media item, not per clip.
/// The OCIO choice (Task 9) is added with that feature.
enum ColorInputTransform: Codable, Hashable, Sendable {
    /// The descriptor decides. Until OCIO exists, V-Log shows as it is recorded.
    case automatic
    /// Show code values as they are (flat-looking V-Log).
    case none
    /// A LUT applied to the decoded code values, such as Panasonic's V-Log to V-709.
    case lut(LUTReference)
}

struct CodedVideoFormat: Equatable, Sendable {
    var bitDepth: Int?
    var chroma: ChromaSubsampling?
}

/// The fields of a Panasonic `com.panasonic.Semi-Pro.metadata.xml` clip item that describe color.
struct PanasonicClipMetadata: Equatable, Sendable {
    static let metadataIdentifier = AVMetadataIdentifier(rawValue: "mdta/com.panasonic.Semi-Pro.metadata.xml")

    var captureGamma: String?
    var captureGamut: String?
    var bitDepth: Int?

    /// Nil for malformed XML or XML without any of these fields.
    init?(xml: String) {
        let reader = Reader()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = reader
        guard parser.parse() else { return nil }
        captureGamma = reader.values["CaptureGamma"]
        captureGamut = reader.values["CaptureGamut"]
        bitDepth = reader.values["BitDepth"].flatMap { Int($0) }
        guard captureGamma != nil || captureGamut != nil || bitDepth != nil else { return nil }
    }

    private final class Reader: NSObject, XMLParserDelegate {
        static let wanted: Set<String> = ["CaptureGamma", "CaptureGamut", "BitDepth"]
        var values: [String: String] = [:]
        private var current: String?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            current = Self.wanted.contains(name) ? name : nil
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if current != nil { text += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == current, values[name] == nil {
                values[name] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            current = nil
        }
    }
}

enum SourceColorDetector {
    /// Camera metadata wins over container tags for transfer and gamut; range and matrix always come
    /// from the format description, which describes the encoded samples themselves.
    static func descriptor(format: CMFormatDescription, panasonicXML: String?) -> SourceColorDescriptor {
        func string(_ key: CFString) -> String? { CMFormatDescriptionGetExtension(format, extensionKey: key) as? String }
        let fullRange = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_FullRangeVideo) as? Bool == true
        let matrices: [String: YCbCrMatrix] = [
            kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String: .rec709,
            kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4 as String: .rec601,
            kCMFormatDescriptionYCbCrMatrix_SMPTE_240M_1995 as String: .rec601,
            kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 as String: .rec2020
        ]
        let matrix = string(kCMFormatDescriptionExtension_YCbCrMatrix).flatMap { matrices[$0] } ?? .unknown
        let taggedTransfer: SourceTransfer = string(kCMFormatDescriptionExtension_TransferFunction)
            == (kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String) ? .rec709 : .unknown
        let taggedGamut: SourceGamut = string(kCMFormatDescriptionExtension_ColorPrimaries)
            == (kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String) ? .rec709 : .unknown
        let coded = codedFormat(format)

        var descriptor = SourceColorDescriptor(
            bitDepth: coded.bitDepth, chroma: coded.chroma,
            range: fullRange ? .full : .video, matrix: matrix,
            transfer: taggedTransfer, gamut: taggedGamut, detectedFrom: .formatDescription
        )
        guard let camera = panasonicXML.flatMap(PanasonicClipMetadata.init(xml:)) else { return descriptor }
        descriptor.detectedFrom = .panasonicMetadata
        descriptor.bitDepth = descriptor.bitDepth ?? camera.bitDepth
        if camera.captureGamma == "V-Log" {
            descriptor.transfer = .vLog
            descriptor.gamut = camera.captureGamut == "V-Gamut" ? .vGamut : .unknown
        }
        return descriptor
    }

    /// Bit depth and chroma subsampling from the codec configuration, when it says.
    static func codedFormat(_ format: CMFormatDescription) -> CodedVideoFormat {
        switch CMFormatDescriptionGetMediaSubType(format) {
        case kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422HQ,
             kCMVideoCodecType_AppleProRes422LT, kCMVideoCodecType_AppleProRes422Proxy:
            return CodedVideoFormat(bitDepth: 10, chroma: .yuv422)
        case kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_AppleProRes4444XQ:
            return CodedVideoFormat(bitDepth: 12, chroma: .yuv444)
        case kCMVideoCodecType_H264:
            return atom("avcC", in: format).map(h264Format) ?? CodedVideoFormat()
        case kCMVideoCodecType_HEVC:
            return atom("hvcC", in: format).map(hevcFormat) ?? CodedVideoFormat()
        default:
            return CodedVideoFormat()
        }
    }

    private static func atom(_ name: String, in format: CMFormatDescription) -> Data? {
        let atoms = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms)
            as? [String: Any]
        return atoms?[name] as? Data
    }

    private static func chroma(_ idc: UInt64) -> ChromaSubsampling? {
        switch idc {
        case 1: .yuv420
        case 2: .yuv422
        case 3: .yuv444
        default: nil
        }
    }

    /// Reads chroma_format_idc and bit_depth_luma_minus8 from the first SPS in an `avcC` record.
    /// The S5's records carry no high-profile extension after the PPS, so the SPS is the source.
    static func h264Format(_ avcC: Data) -> CodedVideoFormat {
        let bytes = [UInt8](avcC)
        guard bytes.count > 8, bytes[5] & 0x1F > 0 else { return CodedVideoFormat() }
        let length = Int(bytes[6]) << 8 | Int(bytes[7])
        guard length >= 4, bytes.count >= 8 + length else { return CodedVideoFormat() }
        let sps = Array(bytes[8 ..< 8 + length])
        let profile = sps[1]
        // Profiles without chroma_format_idc in the SPS are 8-bit 4:2:0.
        guard [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) else {
            return CodedVideoFormat(bitDepth: 8, chroma: .yuv420)
        }
        var reader = BitReader(withoutEmulationPrevention(Array(sps[4...])))
        guard reader.unsignedExpGolomb() != nil, // seq_parameter_set_id
              let chromaIDC = reader.unsignedExpGolomb() else { return CodedVideoFormat() }
        if chromaIDC == 3, reader.bit() == nil { return CodedVideoFormat() } // separate_colour_plane_flag
        guard let depthMinus8 = reader.unsignedExpGolomb(), depthMinus8 <= 8 else { return CodedVideoFormat() }
        return CodedVideoFormat(bitDepth: Int(depthMinus8) + 8, chroma: chroma(chromaIDC))
    }

    /// An `hvcC` record stores chromaFormat and bitDepthLumaMinus8 at fixed offsets.
    static func hevcFormat(_ hvcC: Data) -> CodedVideoFormat {
        let bytes = [UInt8](hvcC)
        guard bytes.count >= 18 else { return CodedVideoFormat() }
        return CodedVideoFormat(bitDepth: Int(bytes[17] & 0x07) + 8, chroma: chroma(UInt64(bytes[16] & 0x03)))
    }

    private static func withoutEmulationPrevention(_ bytes: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var zeros = 0
        for byte in bytes {
            if zeros >= 2, byte == 0x03 { zeros = 0; continue }
            output.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return output
    }

    private struct BitReader {
        private let bytes: [UInt8]
        private var position = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func bit() -> UInt64? {
            guard position < bytes.count * 8 else { return nil }
            defer { position += 1 }
            return UInt64(bytes[position / 8] >> (7 - UInt8(position % 8)) & 1)
        }

        mutating func unsignedExpGolomb() -> UInt64? {
            var leadingZeros = 0
            while true {
                guard let next = bit() else { return nil }
                if next == 1 { break }
                leadingZeros += 1
                if leadingZeros > 31 { return nil }
            }
            var value: UInt64 = 0
            for _ in 0 ..< leadingZeros {
                guard let next = bit() else { return nil }
                value = value << 1 | next
            }
            return (1 << UInt64(leadingZeros)) - 1 + value
        }
    }
}
