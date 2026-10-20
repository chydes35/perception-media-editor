import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The file formats an export recipe can write. Bit depth is part of the format: delivering a
/// 16-bit file from an 8-bit render would only add size.
enum ExportFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case jpeg
    case tiff16
    case png16
    case heic10

    var id: String { rawValue }

    var title: String {
        switch self {
        case .jpeg: "JPEG"
        case .tiff16: "TIFF (16-bit)"
        case .png16: "PNG (16-bit)"
        case .heic10: "HEIC (10-bit)"
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .tiff16: "tif"
        case .png16: "png"
        case .heic10: "heic"
        }
    }

    var contentType: UTType {
        switch self {
        case .jpeg: .jpeg
        case .tiff16: .tiff
        case .png16: .png
        case .heic10: .heic
        }
    }

    /// Lossy formats take a quality setting; TIFF and PNG are lossless.
    var usesQuality: Bool { self == .jpeg || self == .heic10 }

    /// The format a save panel's file extension asks for.
    init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "jpg", "jpeg": self = .jpeg
        case "tif", "tiff": self = .tiff16
        case "png": self = .png16
        case "heic": self = .heic10
        default: return nil
        }
    }
}

/// Sharpening applied to the finished export, after the resize. Camera and edit sharpening are
/// tuned for the full-size picture; a downsized copy needs its own, sized to its pixels.
enum OutputSharpening: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case low
    case standard
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .low: "Low"
        case .standard: "Standard"
        case .high: "High"
        }
    }

    /// `CISharpenLuminance` strength.
    var sharpness: Double {
        switch self {
        case .none: 0
        case .low: 0.25
        case .standard: 0.5
        case .high: 0.85
        }
    }

    /// The radius is a share of the long edge, so a 2,048 px and a 6,000 px export are sharpened to
    /// the same look at the same viewing size.
    static let radiusShareOfLongEdge = 0.0004

    static func radius(forLongEdge longEdge: Double) -> Double {
        max(0.5, longEdge * radiusShareOfLongEdge)
    }

    /// Sharpens luminance on sRGB-encoded values, where equal steps look equal, so a halo is as
    /// visible on the dark side of an edge as on the bright side.
    func apply(to image: CIImage) -> CIImage {
        guard self != .none, !image.extent.isInfinite, !image.extent.isEmpty,
              let space = CGColorSpace(name: CGColorSpace.extendedSRGB),
              let encoded = image.matchedFromWorkingSpace(to: space) else { return image }
        let sharpen = CIFilter.sharpenLuminance()
        // Outside the frame Core Image is transparent, which the filter would read as an edge and
        // brighten the border. Repeating the edge pixels keeps the frame's edge as flat as its middle.
        sharpen.inputImage = encoded.clampedToExtent()
        sharpen.sharpness = Float(sharpness)
        sharpen.radius = Float(Self.radius(forLongEdge: Double(max(image.extent.width, image.extent.height))))
        guard let sharpened = sharpen.outputImage?.cropped(to: image.extent),
              let result = sharpened.matchedToWorkingSpace(from: space) else { return image }
        return result
    }
}

/// What an export writes into the file's metadata.
struct ExportMetadataOptions: Codable, Equatable, Sendable {
    var copyright = ""
    var creator = ""
    /// Drops the GPS location, the camera body and lens serial numbers, the owner name and the
    /// manufacturer's maker notes (which carry serial numbers too). On by default: delivered
    /// photos are shared.
    var removePrivateData = true

    static let maximumCopyrightLength = 200
    static let maximumCreatorLength = 100

    /// Single-line text without control characters, within the length limits.
    var isValid: Bool {
        func clean(_ text: String, _ limit: Int) -> Bool {
            text.count <= limit && !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
        return clean(copyright, Self.maximumCopyrightLength) && clean(creator, Self.maximumCreatorLength)
    }

    init(copyright: String = "", creator: String = "", removePrivateData: Bool = true) {
        self.copyright = copyright
        self.creator = creator
        self.removePrivateData = removePrivateData
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        copyright = try container.decodeIfPresent(String.self, forKey: .copyright) ?? ""
        creator = try container.decodeIfPresent(String.self, forKey: .creator) ?? ""
        removePrivateData = try container.decodeIfPresent(Bool.self, forKey: .removePrivateData) ?? true
    }
}

/// Builds the property dictionary an exported file carries, from the original's.
enum ExportMetadata {
    static func sourceProperties(of url: URL) -> [String: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return [:] }
        return properties
    }

    /// Camera exposure data, lens and capture date stay. The pixel dimensions and orientation are
    /// left to the writer: the export is upright and may be cropped or resized, so the source's
    /// values would be wrong.
    static func properties(from source: [String: Any], options: ExportMetadataOptions) -> [String: Any] {
        var result = source
        let exifKey = kCGImagePropertyExifDictionary as String
        let tiffKey = kCGImagePropertyTIFFDictionary as String
        let iptcKey = kCGImagePropertyIPTCDictionary as String

        var exif = result[exifKey] as? [String: Any] ?? [:]
        exif[kCGImagePropertyExifPixelXDimension as String] = nil
        exif[kCGImagePropertyExifPixelYDimension as String] = nil
        var tiff = result[tiffKey] as? [String: Any] ?? [:]
        tiff[kCGImagePropertyTIFFOrientation as String] = nil
        result[kCGImagePropertyOrientation as String] = 1
        result[kCGImagePropertyPixelWidth as String] = nil
        result[kCGImagePropertyPixelHeight as String] = nil

        if options.removePrivateData {
            result[kCGImagePropertyGPSDictionary as String] = nil
            exif[kCGImagePropertyExifBodySerialNumber as String] = nil
            exif[kCGImagePropertyExifLensSerialNumber as String] = nil
            exif[kCGImagePropertyExifCameraOwnerName as String] = nil
            for key in result.keys where key.hasPrefix("{Maker") { result[key] = nil }
        }

        var iptc = result[iptcKey] as? [String: Any] ?? [:]
        if !options.copyright.isEmpty {
            tiff[kCGImagePropertyTIFFCopyright as String] = options.copyright
            iptc[kCGImagePropertyIPTCCopyrightNotice as String] = options.copyright
        }
        if !options.creator.isEmpty {
            tiff[kCGImagePropertyTIFFArtist as String] = options.creator
            iptc[kCGImagePropertyIPTCByline as String] = [options.creator]
        }
        result[exifKey] = exif.isEmpty ? nil : exif
        result[tiffKey] = tiff.isEmpty ? nil : tiff
        result[iptcKey] = iptc.isEmpty ? nil : iptc
        return result
    }
}
