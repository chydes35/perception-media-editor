import CoreGraphics
import CoreImage
import Foundation
import ImageIO

struct WhiteBalanceReading: Equatable, Sendable {
    var temperature: Double
    var tint: Double
}

/// Translates a click on the displayed (possibly rotated and cropped) photo into the RAW
/// decoder's unrotated pixel coordinates, then asks the decoder to make that point neutral.
/// The resulting Kelvin and tint values are saved, so the regular sliders remain meaningful.
enum WhiteBalanceEyedropper {
    static func rawLocation(
        for source: NormalizedPoint, nativeSize: CGSize,
        orientation: CGImagePropertyOrientation
    ) -> CGPoint? {
        guard nativeSize.width > 1, nativeSize.height > 1,
              source.x.isFinite, source.y.isFinite,
              (0 ... 1).contains(source.x), (0 ... 1).contains(source.y)
        else { return nil }

        // The UI and ImageGeometry use top-left normalized coordinates. neutralLocation uses
        // pixels in the unrotated image, measured from the bottom-left.
        let x = source.x, y = source.y
        let raw: (x: Double, y: Double)
        switch orientation {
        case .up: raw = (x, y)
        case .upMirrored: raw = (1 - x, y)
        case .down: raw = (1 - x, 1 - y)
        case .downMirrored: raw = (x, 1 - y)
        case .leftMirrored: raw = (y, x)
        case .right: raw = (y, 1 - x)
        case .rightMirrored: raw = (1 - y, 1 - x)
        case .left: raw = (1 - y, x)
        @unknown default: return nil
        }
        return CGPoint(
            x: min(nativeSize.width - 1, max(0, raw.x * nativeSize.width)),
            y: min(nativeSize.height - 1, max(0, (1 - raw.y) * nativeSize.height))
        )
    }

    static func sampleRaw(at source: NormalizedPoint, url: URL) -> WhiteBalanceReading? {
        guard PhotoSourceLoader.isRAW(url), let filter = CIRAWFilter(imageURL: url),
              let location = rawLocation(for: source, nativeSize: filter.nativeSize,
                                         orientation: filter.orientation)
        else { return nil }

        filter.neutralLocation = location
        let temperature = Double(filter.neutralTemperature)
        let tint = Double(filter.neutralTint)
        guard temperature.isFinite, tint.isFinite,
              (2000 ... 50000).contains(temperature), (-150 ... 150).contains(tint)
        else { return nil }
        return WhiteBalanceReading(temperature: temperature, tint: tint)
    }
}
