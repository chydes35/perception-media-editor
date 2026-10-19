import Foundation
import ImageIO

/// Camera exposure settings read from EXIF for analysis. Not stored on `MediaAsset` or in the project.
struct ExposureMetadata: Sendable, Equatable {
    var iso: Double
    var exposureTime: Double
    var fNumber: Double

    /// Scene brightness as an ISO 100 exposure value: log2(N² / t) − log2(ISO / 100).
    /// Two frames of the same light have similar values however the camera was set.
    var exposureValue: Double {
        log2(fNumber * fNumber / exposureTime) - log2(iso / 100)
    }

    /// Reads ISO, shutter time and f-number from file metadata without decoding pixels.
    /// Returns nil when any of the three is missing or not positive.
    static func read(_ url: URL) -> ExposureMetadata? {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(
                source, 0, [kCGImageSourceShouldCache: false] as CFDictionary
            ) as? [CFString: Any],
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        else { return nil }
        let isoValues = exif[kCGImagePropertyExifISOSpeedRatings] as? [Double]
        guard
            let iso = isoValues?.first ?? (exif[kCGImagePropertyExifISOSpeedRatings] as? Double),
            let time = exif[kCGImagePropertyExifExposureTime] as? Double,
            let fNumber = exif[kCGImagePropertyExifFNumber] as? Double,
            iso > 0, time > 0, fNumber > 0
        else { return nil }
        return ExposureMetadata(iso: iso, exposureTime: time, fNumber: fNumber)
    }
}
