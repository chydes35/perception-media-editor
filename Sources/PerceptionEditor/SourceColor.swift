@preconcurrency import AVFoundation
import Foundation

enum YCbCrRange: String, Codable, Sendable { case video, full }
enum YCbCrMatrix: String, Codable, Sendable { case rec709, rec601, rec2020, unknown }
enum ChromaSubsampling: String, Codable, Sendable {
    case yuv420 = "4:2:0", yuv422 = "4:2:2", yuv444 = "4:4:4"
}
/// What the pipeline knows. HLG and PQ are recorded but shown without tone mapping (HDR is out
/// of scope); Apple Log 2 and other camera logs are `.unknown`.
enum SourceTransfer: String, Codable, Sendable { case rec709, vLog, appleLog, hlg, pq, unknown }
enum SourceGamut: String, Codable, Sendable { case rec709, vGamut, rec2020, unknown }
enum SourceColorEvidence: String, Codable, Sendable {
    /// The format description's log key (`kCMFormatDescriptionExtension_LogTransferFunction`),
    /// which iPhone Apple Log clips carry.
    case logTransferKey = "log-transfer-key"
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

    var isLog: Bool { transfer == .vLog || transfer == .appleLog }
    var isHDR: Bool { transfer == .hlg || transfer == .pq }
    /// The file says it is log footage, but in a curve the pipeline does not know (Apple Log 2).
    var isUnsupportedLog: Bool { detectedFrom == .logTransferKey && transfer == .unknown }

    /// For the inspector, e.g. "V-Log / V-Gamut (camera metadata), 10-bit 4:2:2, full range".
    var summary: String {
        let curve: String = switch (transfer, gamut) {
        case (.vLog, .vGamut): "V-Log / V-Gamut"
        case (.vLog, _): "V-Log"
        case (.appleLog, _): "Apple Log / BT.2020"
        case (.hlg, _): "HDR (HLG)"
        case (.pq, _): "HDR (PQ)"
        case (.rec709, _): "Rec. 709"
        case (.unknown, _): isUnsupportedLog ? "Unsupported log" : "Unknown color"
        }
        let source = switch detectedFrom {
        case .panasonicMetadata: " (camera metadata)"
        case .logTransferKey: " (log transfer key)"
        case .formatDescription: ""
        }
        let format = [bitDepth.map { "\($0)-bit" }, chroma?.rawValue].compactMap { $0 }.joined(separator: " ")
        let rangeText = range == .full ? "full range" : "video range"
        return "\(curve)\(source), " + (format.isEmpty ? rangeText : "\(format), \(rangeText)")
    }
}

/// How a source's code values become picture color. Set per media item, not per clip.
enum ColorInputTransform: Codable, Hashable, Sendable {
    /// The descriptor decides: footage detected as V-Log or Apple Log goes through `aces`, the rest
    /// shows as recorded.
    case automatic
    /// Show code values as they are (flat-looking V-Log).
    case none
    /// A LUT applied to the decoded code values, such as Panasonic's V-Log to V-709.
    case lut(LUTReference)
    /// The camera's log (V-Log / V-Gamut, or Apple Log) through OpenColorIO into scene-linear
    /// Rec. 709, graded there, then shown through the ACES 2.0 SDR 100 nits Rec. 709 view. On
    /// footage not detected as log it applies V-Log's transform (V-Log whose metadata was lost).
    case aces
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
    /// Transfer and gamut come, in order, from the format description's log key (Apple Log), the
    /// camera's clip metadata (Panasonic), and the container's tags. Range and matrix always come
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
        let transfers: [String: SourceTransfer] = [
            kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String: .rec709,
            kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String: .hlg,
            kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String: .pq
        ]
        let taggedTransfer = string(kCMFormatDescriptionExtension_TransferFunction).flatMap { transfers[$0] } ?? .unknown
        let gamuts: [String: SourceGamut] = [
            kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String: .rec709,
            kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String: .rec2020
        ]
        let taggedGamut = string(kCMFormatDescriptionExtension_ColorPrimaries).flatMap { gamuts[$0] } ?? .unknown
        let coded = codedFormat(format)

        var descriptor = SourceColorDescriptor(
            bitDepth: coded.bitDepth, chroma: coded.chroma,
            range: fullRange ? .full : .video, matrix: matrix,
            transfer: taggedTransfer, gamut: taggedGamut, detectedFrom: .formatDescription
        )
        // iPhone Apple Log: BT.2020 primaries with no transfer tag, identified only by this key.
        if let log = string(kCMFormatDescriptionExtension_LogTransferFunction) {
            descriptor.detectedFrom = .logTransferKey
            if log == (kCMFormatDescriptionLogTransferFunction_AppleLog as String) {
                descriptor.transfer = .appleLog
                descriptor.gamut = .rec2020
            } else {
                // Apple Log 2 (Apple Gamut) or a newer curve: log, but not one the pipeline renders.
                descriptor.transfer = .unknown
                descriptor.gamut = .unknown
            }
            return descriptor
        }
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
