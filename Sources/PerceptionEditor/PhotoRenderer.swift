import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// A rendered bitmap that can cross from the render actor to the main actor.
/// `CGImage` is immutable, so sharing it between isolation domains is safe.
struct RenderedImage: @unchecked Sendable {
    let cgImage: CGImage
}

struct PhotoPreviewResult: Sendable {
    var edited: RenderedImage
    var histogram: HistogramData
}

struct PhotoMetadata: Sendable, Equatable {
    var width: Int
    var height: Int
    var captureDate: Date?
}

enum PhotoSourceLoader {
    /// Pixel dimensions after EXIF orientation, read from file metadata without decoding pixels.
    static func dimensions(of url: URL) -> (width: Int, height: Int)? {
        metadata(of: url).map { ($0.width, $0.height) }
    }

    /// Dimensions and capture time from file metadata, without decoding pixels.
    static func metadata(of url: URL) -> PhotoMetadata? {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(
                source,
                0,
                [kCGImageSourceShouldCache: false] as CFDictionary
            ) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }

        let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let captured = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String).flatMap(parseEXIFDate)
        return (5 ... 8).contains(orientation)
            ? PhotoMetadata(width: height, height: width, captureDate: captured)
            : PhotoMetadata(width: width, height: height, captureDate: captured)
    }

    /// EXIF stores local time as `yyyy:MM:dd HH:mm:ss` with no time zone.
    static func parseEXIFDate(_ text: String) -> Date? {
        let parts = text.split(whereSeparator: { $0 == ":" || $0 == " " }).compactMap { Int($0) }
        guard parts.count == 6 else { return nil }
        return Calendar.current.date(from: DateComponents(
            year: parts[0], month: parts[1], day: parts[2],
            hour: parts[3], minute: parts[4], second: parts[5]
        ))
    }

    /// A screen-sized image for culling. RAW files use the camera's embedded JPEG
    /// (1920×1280 on a Lumix S5, ≈15 ms). The size cap must stay above the embedded size:
    /// a smaller cap makes ImageIO fall back to a full RAW decode (≈470 ms).
    static func loadCullPreview(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let cap = 2560
        let raw = isRAW(url)

        if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            raw ? kCGImageSourceCreateThumbnailFromImageIfAbsent : kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: cap
        ] as CFDictionary), !raw || max(image.width, image.height) >= 1200 {
            return image
        }

        // A RAW without a usable embedded preview: decode it once at reduced size.
        guard let decoded = load(url, maxDimension: CGFloat(cap)) else { return nil }
        return CIContext().createCGImage(decoded, from: decoded.extent.integral)
    }

    static func isRAW(_ url: URL) -> Bool {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        return type?.conforms(to: .rawImage) == true
    }

    /// Loads an oriented source image. When `maxDimension` is set, the decoder works at a
    /// reduced resolution: RAW files use the RAW engine's scale factor so highlight headroom
    /// survives, and other formats use ImageIO's downsampling.
    static func load(_ url: URL, maxDimension: CGFloat?) -> CIImage? {
        if isRAW(url), let raw = CIRAWFilter(imageURL: url) {
            if let maxDimension {
                let native = raw.nativeSize
                let longest = max(native.width, native.height)
                if longest > 0 {
                    raw.scaleFactor = Float(min(1, maxDimension / longest))
                }
            }
            return raw.outputImage
        }

        if let maxDimension {
            guard
                let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension)
                ] as CFDictionary)
            else { return nil }
            return CIImage(cgImage: thumbnail)
        }

        return CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
    }

    /// Thumbnail-sized source. RAW files use the camera's embedded JPEG preview, which
    /// loads about 50× faster than a RAW decode (≈23 ms vs ≈1.1 s for a Lumix S5 RW2);
    /// the trade-off is that browse thumbnails show the camera's rendering, not the RAW engine's.
    static func loadThumbnail(_ url: URL, maxDimension: CGFloat) -> CIImage? {
        if isRAW(url),
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let embedded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
               kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension)
           ] as CFDictionary),
           CGFloat(max(embedded.width, embedded.height)) >= maxDimension / 2 {
            return CIImage(cgImage: embedded)
        }
        return load(url, maxDimension: maxDimension)
    }
}

/// Renders photo previews, thumbnails, and exports away from the main actor.
///
/// Editing works on a reduced-resolution "working" source (the longest edge is capped at
/// `workingDimension`). Only a few working sources stay in memory at once, and full-resolution
/// decodes happen only for export, which keeps a 200-image RAW session inside an 8 GB Mac.
actor PhotoRenderer {
    static let workingDimension: CGFloat = 2560
    static let previewDimension: CGFloat = 1800
    static let thumbnailDimension: CGFloat = 420

    private let context = CIContext(options: [
        .cacheIntermediates: false,
        .useSoftwareRenderer: false
    ])
    private let workingColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private let displayColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let workingCacheLimit: Int
    private var workingSources: [(key: String, image: CIImage)] = []

    init(workingCacheLimit: Int = 4) {
        self.workingCacheLimit = workingCacheLimit
    }

    /// The edited preview and its histogram for the selected photo.
    func preview(url: URL, adjustments: PhotoAdjustments) -> PhotoPreviewResult? {
        guard let source = workingSource(for: url) else { return nil }
        let edited = MediaColorRenderer.render(source, adjustments: adjustments, includesGeometry: true)
        guard let image = bitmap(edited, maxDimension: Self.previewDimension) else { return nil }
        return PhotoPreviewResult(edited: image, histogram: histogram(of: image.cgImage))
    }

    func original(url: URL) -> RenderedImage? {
        guard let source = workingSource(for: url) else { return nil }
        return bitmap(source, maxDimension: Self.previewDimension)
    }

    /// Thumbnails decode at thumbnail size and are never kept in the working cache.
    func thumbnail(url: URL, adjustments: PhotoAdjustments) -> RenderedImage? {
        guard let source = PhotoSourceLoader.loadThumbnail(url, maxDimension: Self.thumbnailDimension) else {
            return nil
        }
        let edited = MediaColorRenderer.render(source, adjustments: adjustments, includesGeometry: true)
        return bitmap(edited, maxDimension: Self.thumbnailDimension)
    }

    func export(
        url: URL,
        adjustments: PhotoAdjustments,
        to destination: URL,
        type: UTType,
        quality: CGFloat = 0.92
    ) throws {
        guard let source = PhotoSourceLoader.load(url, maxDimension: nil) else {
            throw PhotoRenderError.unreadableSource(url.lastPathComponent)
        }
        let image = MediaColorRenderer.render(source, adjustments: adjustments, includesGeometry: true)

        if type == .png {
            try context.writePNGRepresentation(
                of: image,
                to: destination,
                format: .RGBA8,
                colorSpace: displayColorSpace
            )
        } else {
            try context.writeJPEGRepresentation(
                of: image,
                to: destination,
                colorSpace: displayColorSpace,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
            )
        }
    }

    /// Drops any cached working source for a file that was relinked or changed on disk.
    func evict(url: URL) {
        let prefix = url.path + "|"
        workingSources.removeAll { $0.key.hasPrefix(prefix) }
    }

    func evictAll() {
        workingSources.removeAll()
    }

    var cachedWorkingSourceCount: Int { workingSources.count }

    // MARK: - Working sources

    private func workingSource(for url: URL) -> CIImage? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate?.timeIntervalSinceReferenceDate) ?? 0
        let key = "\(url.path)|\(modified)"

        if let index = workingSources.firstIndex(where: { $0.key == key }) {
            let entry = workingSources.remove(at: index)
            workingSources.append(entry)
            return entry.image
        }

        guard let decoded = PhotoSourceLoader.load(url, maxDimension: Self.workingDimension) else {
            return nil
        }
        // Materialize once in a linear half-float space so repeated slider renders do not
        // re-run RAW demosaicing, while exposure and highlight edits keep their headroom.
        let extent = decoded.extent.integral
        guard let materialized = context.createCGImage(
            decoded,
            from: extent,
            format: .RGBAh,
            colorSpace: workingColorSpace
        ) else { return nil }

        let image = CIImage(cgImage: materialized)
        workingSources.append((key, image))
        if workingSources.count > workingCacheLimit {
            workingSources.removeFirst(workingSources.count - workingCacheLimit)
        }
        return image
    }

    // MARK: - Rendering

    private func bitmap(_ image: CIImage, maxDimension: CGFloat) -> RenderedImage? {
        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite else {
            return nil
        }
        let scale = min(1, maxDimension / max(extent.width, extent.height))
        let normalized = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let scaled = scale < 1
            ? normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : normalized
        guard let cgImage = context.createCGImage(
            scaled,
            from: scaled.extent.integral,
            format: .RGBA8,
            colorSpace: displayColorSpace
        ) else { return nil }
        return RenderedImage(cgImage: cgImage)
    }

    /// Builds the RGB histogram from the already-rendered preview instead of rendering again.
    private func histogram(of cgImage: CGImage) -> HistogramData {
        let maximumDimension = 256.0
        let scale = min(1, maximumDimension / Double(max(cgImage.width, cgImage.height)))
        let width = max(1, Int(Double(cgImage.width) * scale))
        let height = max(1, Int(Double(cgImage.height) * scale))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let baseAddress = buffer.baseAddress,
                let bitmap = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: displayColorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { return false }
            bitmap.interpolationQuality = .low
            bitmap.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return .empty }

        var red = [Double](repeating: 0, count: 256)
        var green = [Double](repeating: 0, count: 256)
        var blue = [Double](repeating: 0, count: 256)

        // Transparent pixels (straighten corners) are not part of the photo.
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] > 0 {
            red[Int(pixels[index])] += 1
            green[Int(pixels[index + 1])] += 1
            blue[Int(pixels[index + 2])] += 1
        }

        return HistogramData(red: normalize(red), green: normalize(green), blue: normalize(blue))
    }

    private func normalize(_ channel: [Double]) -> [Double] {
        let peak = channel.max() ?? 0
        guard peak > 0 else { return channel }
        return channel.map { $0 / peak }
    }
}

enum PhotoRenderError: LocalizedError {
    case unreadableSource(String)

    var errorDescription: String? {
        switch self {
        case .unreadableSource(let filename):
            "\(filename) could not be read. Relink it from the Photo or Library workspace."
        }
    }
}
