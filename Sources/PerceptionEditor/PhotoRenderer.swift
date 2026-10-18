import CoreImage
import CoreVideo
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
    /// The selected mask as a red tint (opaque where the mask applies), the same size as `edited`.
    var maskOverlay: RenderedImage?
}

/// A 1:1 pixel render of part of a photo, for checking focus at 100%.
struct FocusRender: Sendable {
    var image: RenderedImage
    /// Size of the whole finished photo (after crop and rotation), in pixels.
    var fullSize: CGSize
    /// The part of the photo that `image` shows, in pixels from the top-left corner.
    var region: CGRect
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

    /// The RAW engine's filter for a file with `settings` applied. Extended range stays on so
    /// highlights above white survive the decode and later exposure and highlight edits can
    /// recover them, as they can in Lightroom; with the engine's default they are clipped for good.
    static func makeRawFilter(_ url: URL, settings: RawSettings, maxDimension: CGFloat?) -> CIRAWFilter? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        filter.extendedDynamicRangeAmount = 2

        if let maxDimension {
            let native = filter.nativeSize
            let longest = max(native.width, native.height)
            if longest > 0 { filter.scaleFactor = Float(min(1, maxDimension / longest)) }
        }

        // Temperature and tint are coupled, so set both from the as-shot values when only one is given.
        applyWhiteBalance(settings, to: filter)
        if filter.isLuminanceNoiseReductionSupported, let value = settings.luminanceNoiseReduction {
            filter.luminanceNoiseReductionAmount = Float(min(1, max(0, value)))
        }
        if filter.isColorNoiseReductionSupported, let value = settings.colorNoiseReduction {
            filter.colorNoiseReductionAmount = Float(min(1, max(0, value)))
        }
        if filter.isSharpnessSupported, let value = settings.sharpness {
            filter.sharpnessAmount = Float(min(1, max(0, value)))
        }
        if filter.isDetailSupported, let value = settings.detail {
            filter.detailAmount = Float(min(3, max(0, value)))
        }
        if filter.isLensCorrectionSupported, let enabled = settings.lensCorrection {
            filter.isLensCorrectionEnabled = enabled
        }
        return filter
    }

    /// Sets temperature and tint on `filter`. Both come from the as-shot values when only one is given,
    /// so `filter` must not have had a white balance applied yet unless `settings` carries both.
    static func applyWhiteBalance(_ settings: RawSettings, to filter: CIRAWFilter) {
        guard settings.hasWhiteBalance else { return }
        let temperature = settings.temperature ?? Double(filter.neutralTemperature)
        let tint = settings.tint ?? Double(filter.neutralTint)
        filter.neutralTemperature = Float(min(50000, max(2000, temperature)))
        filter.neutralTint = Float(min(150, max(-150, tint)))
    }

    /// As-shot white balance and the RAW engine's defaults for a file.
    static func rawInfo(of url: URL) -> RawInfo? {
        guard isRAW(url), let filter = CIRAWFilter(imageURL: url) else { return nil }
        return RawInfo(
            asShotTemperature: Double(filter.neutralTemperature),
            asShotTint: Double(filter.neutralTint),
            defaultLuminanceNoiseReduction: Double(filter.luminanceNoiseReductionAmount),
            defaultColorNoiseReduction: Double(filter.colorNoiseReductionAmount),
            defaultSharpness: Double(filter.sharpnessAmount),
            defaultDetail: Double(filter.detailAmount),
            supportsNoiseReduction: filter.isLuminanceNoiseReductionSupported && filter.isColorNoiseReductionSupported,
            supportsSharpness: filter.isSharpnessSupported,
            supportsDetail: filter.isDetailSupported,
            supportsLensCorrection: filter.isLensCorrectionSupported,
            lensCorrectionDefault: filter.isLensCorrectionEnabled
        )
    }

    /// Loads an oriented source image. When `maxDimension` is set, the decoder works at a
    /// reduced resolution: RAW files use the RAW engine's scale factor so highlight headroom
    /// survives, and other formats use ImageIO's downsampling. `raw` only affects RAW files.
    static func load(_ url: URL, maxDimension: CGFloat?, raw: RawSettings = RawSettings()) -> CIImage? {
        if isRAW(url), let filter = makeRawFilter(url, settings: raw, maxDimension: maxDimension) {
            return filter.outputImage
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
    /// A RAW photo with its own RAW settings (white balance, noise reduction) is decoded instead,
    /// so its thumbnail reflects the edit.
    static func loadThumbnail(_ url: URL, maxDimension: CGFloat, raw: RawSettings = RawSettings()) -> CIImage? {
        if isRAW(url), !raw.isDefault {
            return load(url, maxDimension: maxDimension, raw: raw)
        }
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
        return load(url, maxDimension: maxDimension, raw: raw)
    }
}

/// Renders photo previews, thumbnails, and exports away from the main actor.
///
/// Editing works on a reduced-resolution "working" source (the longest edge is capped at
/// `workingDimension`). Only a few working sources stay in memory at once, and full-resolution
/// decodes happen only for export and for the 100% view. Render-context memory targets and
/// lifecycle cleanup reduce shared-memory pressure. Working sources live in GPU-shared pixel buffers, so a slider drag
/// re-renders from memory instead of re-running the RAW decode.
actor PhotoRenderer {
    static let workingDimension: CGFloat = 2560
    static let previewDimension: CGFloat = 1800
    static let thumbnailDimension: CGFloat = 420
    /// Photos above this many pixels are not held at full resolution (a 24 MP frame takes 192 MB).
    static let maximumFullResolutionPixels = 90_000_000.0

    private struct WorkingEntry {
        var url: String
        var rawKey: String
        var image: CIImage
    }

    private let context: CIContext
    private let memoryTargetMB: Int?
    private var repairContext: CIContext?
    private let workingColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private let displayColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let workingCacheLimit: Int
    private var workingSources: [WorkingEntry] = []
    private var fullResolution: WorkingEntry?
    private var rawInfoCache: [String: RawInfo?] = [:]

    /// One RAW filter kept for the current photo so white-balance changes re-render from the
    /// engine's cached demosaic (about 90 ms) instead of building and decoding a new filter (330-700 ms).
    private struct HeldRawFilter {
        var url: String
        /// Every RAW setting except white balance; the filter is only reused while these match.
        var otherSettingsKey: String
        var filter: CIRAWFilter
        /// The camera's white balance, restored when an edit clears temperature or tint.
        var asShotTemperature: Float
        var asShotTint: Float
    }
    private var heldRawFilter: HeldRawFilter?

    /// The context budget controls temporary render allocations, not the entire process.
    /// Half-float working precision is retained for RAW highlight recovery.
    init(workingCacheLimit: Int = 4, memoryTargetMB: Int? = 256) {
        self.workingCacheLimit = max(0, workingCacheLimit)
        self.memoryTargetMB = memoryTargetMB
        var options: [CIContextOption: Any] = [.cacheIntermediates: false, .useSoftwareRenderer: false]
        if let memoryTargetMB { options[.memoryTarget] = max(1, memoryTargetMB) }
        context = CIContext(options: options)
    }

    /// Full-resolution healing needs more than 128 MiB for its color-matching blur.
    /// Keep a bounded 256 MiB target, preserving the normal target for other edits.
    private func fullResolutionContext(for adjustments: PhotoAdjustments) -> CIContext {
        guard let memoryTargetMB, memoryTargetMB < 256,
              adjustments.retouches.contains(where: {
                  $0.kind == .heal && $0.isEnabled && $0.opacity > 0 && !$0.points.isEmpty
              }) else { return context }
        if let repairContext { return repairContext }
        let newContext = CIContext(options: [
            .cacheIntermediates: false, .useSoftwareRenderer: false, .memoryTarget: 256
        ])
        repairContext = newContext
        return newContext
    }

    func preview(url: URL, adjustments: PhotoAdjustments, overlayMaskID: UUID? = nil) -> PhotoPreviewResult? {
        return autoreleasepool {
            guard let source = workingSource(for: url, raw: adjustments.raw) else {
                PhotoPreviewDiagnostics.record("renderer preview source unavailable")
                return nil
            }
            let edited = MediaColorRenderer.render(source, adjustments: adjustments, includesGeometry: true)
            guard let image = bitmap(edited, maxDimension: Self.previewDimension) else {
                PhotoPreviewDiagnostics.record("renderer preview bitmap unavailable")
                return nil
            }

            var overlay: RenderedImage?
            if let overlayMaskID, let mask = adjustments.masks.first(where: { $0.id == overlayMaskID }) {
                overlay = maskOverlay(for: mask, source: source, adjustments: adjustments)
            }
            let data = histogram(of: image.cgImage)
            PhotoPreviewDiagnostics.record("renderer preview width=\(image.cgImage.width) height=\(image.cgImage.height) histogram=\(data.hasValues) nonzeroBins=\(data.red.filter { $0 > 0 }.count),\(data.green.filter { $0 > 0 }.count),\(data.blue.filter { $0 > 0 }.count) overlay=\(overlay != nil)")
            return PhotoPreviewResult(edited: image, histogram: data, maskOverlay: overlay)
        }
    }

    /// A mask as a red tint over the finished picture: it follows the photo through rotation,
    /// straighten, and crop, and is rendered on the same grid as the preview so they line up.
    private func maskOverlay(for mask: LocalMask, source: CIImage, adjustments: PhotoAdjustments) -> RenderedImage? {
        let weights = MaskRenderer.image(for: mask, extent: source.extent)
        let finished = MediaColorRenderer.finishedGeometry(weights, adjustments)
        // Red, with the mask value as its opacity.
        let tinted = finished.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 1, y: 0.1, z: 0.1, w: 0)
        ])
        return bitmap(tinted, maxDimension: Self.previewDimension)
    }

    func subjectSelectionOverlay(url: URL, png: Data, adjustments: PhotoAdjustments) -> RenderedImage? {
        guard let source = workingSource(for: url, raw: adjustments.raw) else { return nil }
        let mask = LocalMask(shape: .subject(SubjectMask(png: png)))
        return maskOverlay(for: mask, source: source, adjustments: adjustments)
    }

    /// The photo as the RAW engine renders it with no edits, for before/after.
    func original(url: URL) -> RenderedImage? {
        return autoreleasepool {
            guard let source = workingSource(for: url, raw: RawSettings()) else { return nil }
            return bitmap(source, maxDimension: Self.previewDimension)
        }
    }

    /// As-shot white balance and engine defaults, or nil for a file that is not RAW.
    func rawInfo(url: URL) -> RawInfo? {
        return autoreleasepool {
            let key = cacheKey(for: url)
            if let cached = rawInfoCache[key] { return cached }
            let info = PhotoSourceLoader.rawInfo(of: url)
            rawInfoCache[key] = .some(info)
            return info
        }
    }

    /// Uses the RAW decoder's native neutral-point calculation away from the UI thread.
    func whiteBalance(at source: NormalizedPoint, url: URL) -> WhiteBalanceReading? {
        WhiteBalanceEyedropper.sampleRaw(at: source, url: url)
    }


    /// Thumbnails decode at thumbnail size and are never kept in the working cache.
    func thumbnail(url: URL, adjustments: PhotoAdjustments) -> RenderedImage? {
        return autoreleasepool {
            guard let source = PhotoSourceLoader.loadThumbnail(
                url,
                maxDimension: Self.thumbnailDimension,
                raw: adjustments.raw
            ) else {
                return nil
            }
            let edited = MediaColorRenderer.render(source, adjustments: adjustments, includesGeometry: true)
            return bitmap(edited, maxDimension: Self.thumbnailDimension)
        }
    }

    func export(
        url: URL,
        adjustments: PhotoAdjustments,
        to destination: URL,
        type: UTType,
        quality: CGFloat = 0.92,
        protectedOriginals: [URL] = [],
        longEdgePixels: Int? = nil,
        replaceExisting: Bool = true
    ) throws {
        defer { clearRenderCaches() }
        try autoreleasepool {
            let exportContext = fullResolutionContext(for: adjustments)
            let originals = protectedOriginals + [url]
            try ExportFileSafety.validate(destination, protecting: originals)
            guard let source = PhotoSourceLoader.load(url, maxDimension: nil, raw: adjustments.raw) else {
                throw PhotoRenderError.unreadableSource(url.lastPathComponent)
            }
            var image = MediaColorRenderer.render(source, adjustments: adjustments, includesGeometry: true)
            if let longEdgePixels, longEdgePixels > 0 {
                let currentLongEdge = max(image.extent.width, image.extent.height)
                if currentLongEdge > CGFloat(longEdgePixels) {
                    let resize = CIFilter.lanczosScaleTransform()
                    resize.inputImage = image
                    resize.scale = Float(CGFloat(longEdgePixels) / currentLongEdge)
                    resize.aspectRatio = 1
                    image = resize.outputImage ?? image
                }
            }

            try ExportFileSafety.writeAtomically(
                to: destination, protecting: originals, replaceExisting: replaceExisting
            ) { temporary in
                if type == .png {
                    try exportContext.writePNGRepresentation(
                        of: image, to: temporary, format: .RGBA8, colorSpace: displayColorSpace
                    )
                } else {
                    try exportContext.writeJPEGRepresentation(
                        of: image, to: temporary, colorSpace: displayColorSpace,
                        options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
                    )
                }
            }
        }
    }

    // MARK: - 100% view

    /// A 1:1 pixel render of the part of the finished photo around `center`, for checking focus.
    /// The first call for a photo decodes it at full resolution (about a second for a 24 MP RAW)
    /// and keeps that one buffer, so panning afterwards renders in milliseconds.
    /// `center` is normalized (0–1) from the top-left of the finished photo.
    func focusRegion(
        url: URL,
        adjustments: PhotoAdjustments,
        center: CGPoint,
        viewportPixels: CGSize
    ) -> FocusRender? {
        return autoreleasepool {
            guard viewportPixels.width >= 1, viewportPixels.height >= 1,
                  let source = fullResolutionSource(for: url, raw: adjustments.raw)
            else { return nil }

            let finished = MediaColorRenderer.render(source, adjustments: adjustments, includesGeometry: true)
            let extent = finished.extent.integral
            guard extent.width >= 1, extent.height >= 1 else { return nil }

            let width = min(extent.width, viewportPixels.width.rounded())
            let height = min(extent.height, viewportPixels.height.rounded())
            let left = min(max(0, center.x * extent.width - width / 2), extent.width - width).rounded()
            let top = min(max(0, center.y * extent.height - height / 2), extent.height - height).rounded()
            // Core Image measures from the bottom-left corner.
            let region = CGRect(x: extent.minX + left, y: extent.minY + extent.height - top - height, width: width, height: height)

            guard let cgImage = fullResolutionContext(for: adjustments).createCGImage(
                finished.cropped(to: region),
                from: region,
                format: .RGBA8,
                colorSpace: displayColorSpace
            ) else { return nil }

            return FocusRender(
                image: RenderedImage(cgImage: cgImage),
                fullSize: extent.size,
                region: CGRect(x: left, y: top, width: width, height: height)
            )
        }
    }

    /// Frees the full-resolution buffer once the 100% view is closed.
    func releaseFullResolution() {
        fullResolution = nil
        clearRenderCaches()
    }

    func clearRenderCaches() {
        context.clearCaches()
        repairContext?.clearCaches()
        repairContext = nil
    }

    func releaseMemoryUnderPressure() {
        // Preserve only the most recent source(s), so the visible photo stays responsive.
        if workingSources.count > 2 { workingSources.removeFirst(workingSources.count - 2) }
        heldRawFilter = nil
        rawInfoCache.removeAll()
        clearRenderCaches()
    }

    var hasFullResolution: Bool { fullResolution != nil }

    private func fullResolutionSource(for url: URL, raw: RawSettings) -> CIImage? {
        let rawKey = rawKey(for: url, raw: raw)
        if let entry = fullResolution, entry.url == cacheKey(for: url), entry.rawKey == rawKey {
            return entry.image
        }
        fullResolution = nil

        guard let decoded = PhotoSourceLoader.load(url, maxDimension: nil, raw: raw) else { return nil }
        let extent = decoded.extent
        guard extent.width * extent.height <= Self.maximumFullResolutionPixels,
              let image = materialize(decoded)
        else { return nil }

        fullResolution = WorkingEntry(url: cacheKey(for: url), rawKey: rawKey, image: image)
        return image
    }

    // MARK: - Working sources

    /// Drops any cached working source for a file that was relinked or changed on disk.
    func evict(url: URL) {
        let prefix = url.path + "|"
        workingSources.removeAll { $0.url.hasPrefix(prefix) }
        if heldRawFilter?.url.hasPrefix(prefix) == true { heldRawFilter = nil }
        rawInfoCache = rawInfoCache.filter { !$0.key.hasPrefix(prefix) }
        if fullResolution?.url.hasPrefix(prefix) == true { fullResolution = nil }
    }

    func evictAll() {
        workingSources.removeAll()
        heldRawFilter = nil
        fullResolution = nil
        rawInfoCache.removeAll()
        clearRenderCaches()
    }

    var cachedWorkingSourceCount: Int { workingSources.count }

    private func cacheKey(for url: URL) -> String {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate?.timeIntervalSinceReferenceDate) ?? 0
        return "\(url.path)|\(modified)"
    }

    /// RAW settings only matter to RAW files; every other file shares one decode.
    private func rawKey(for url: URL, raw: RawSettings) -> String {
        PhotoSourceLoader.isRAW(url) ? raw.cacheKey : RawSettings().cacheKey
    }

    /// Decodes `url` at working size. A RAW photo keeps its filter from its first decode, so the
    /// first white balance edit and each one after it only mutate that filter; any other RAW change
    /// starts a new filter.
    private func decode(_ url: URL, key: String, raw: RawSettings) -> CIImage? {
        guard PhotoSourceLoader.isRAW(url) else {
            return PhotoSourceLoader.load(url, maxDimension: Self.workingDimension, raw: raw)
        }
        let otherKey = raw.withoutWhiteBalance.cacheKey
        if var held = heldRawFilter, held.url == key, held.otherSettingsKey == otherKey {
            Self.setWhiteBalance(raw, on: &held)
            heldRawFilter = held
            return held.filter.outputImage
        }
        heldRawFilter = nil
        guard let filter = PhotoSourceLoader.makeRawFilter(url, settings: raw.withoutWhiteBalance, maxDimension: Self.workingDimension)
        else { return nil }
        var held = HeldRawFilter(
            url: key, otherSettingsKey: otherKey, filter: filter,
            asShotTemperature: filter.neutralTemperature, asShotTint: filter.neutralTint)
        Self.setWhiteBalance(raw, on: &held)
        heldRawFilter = held
        return filter.outputImage
    }

    /// A small render of the held-filter decode, so tests can compare it without moving a `CIImage` out of the actor.
    func heldDecodeThumbnail(url: URL, raw: RawSettings, width: CGFloat) -> CGImage? {
        guard let image = decode(url, key: cacheKey(for: url), raw: raw), image.extent.width > 0 else { return nil }
        let scaled = image.transformed(by: CGAffineTransform(scaleX: width / image.extent.width, y: width / image.extent.width))
        return context.createCGImage(scaled, from: scaled.extent, format: .RGBA8, colorSpace: displayColorSpace)
    }

    /// Both values are set every time, so a temperature or tint that goes back to unset returns to as-shot.
    private static func setWhiteBalance(_ raw: RawSettings, on held: inout HeldRawFilter) {
        let temperature = raw.temperature.map { Float(min(50000, max(2000, $0))) } ?? held.asShotTemperature
        let tint = raw.tint.map { Float(min(150, max(-150, $0))) } ?? held.asShotTint
        if held.filter.neutralTemperature != temperature { held.filter.neutralTemperature = temperature }
        if held.filter.neutralTint != tint { held.filter.neutralTint = tint }
    }

    private func workingSource(for url: URL, raw: RawSettings) -> CIImage? {
        let key = cacheKey(for: url)
        let variant = rawKey(for: url, raw: raw)
        let defaultVariant = RawSettings().cacheKey
        if let held = heldRawFilter, held.url != key { heldRawFilter = nil }

        if let index = workingSources.firstIndex(where: { $0.url == key && $0.rawKey == variant }) {
            let entry = workingSources.remove(at: index)
            workingSources.append(entry)
            return entry.image
        }

        guard let decoded = decode(url, key: key, raw: raw),
              let image = materialize(decoded)
        else { return nil }

        // A photo keeps its untouched decode plus at most one edited variant, so dragging a
        // white balance slider replaces the previous frame instead of filling the cache.
        if variant != defaultVariant {
            workingSources.removeAll { $0.url == key && $0.rawKey != defaultVariant }
        }
        workingSources.append(WorkingEntry(url: key, rawKey: variant, image: image))
        if workingSources.count > workingCacheLimit {
            workingSources.removeFirst(workingSources.count - workingCacheLimit)
        }
        return image
    }

    /// Renders `image` once into a half-float, GPU-shared pixel buffer in linear light, so later
    /// renders read from memory and exposure and highlight edits keep their headroom.
    private func materialize(_ image: CIImage) -> CIImage? {
        let extent = image.extent.integral
        guard extent.width >= 1, extent.height >= 1, extent.width.isFinite, extent.height.isFinite else {
            return nil
        }

        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil,
            Int(extent.width),
            Int(extent.height),
            kCVPixelFormatType_64RGBAHalf,
            [
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true
            ] as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else { return nil }

        let origin = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        context.render(
            origin,
            to: buffer,
            bounds: CGRect(origin: .zero, size: extent.size),
            colorSpace: workingColorSpace
        )
        return CIImage(cvPixelBuffer: buffer, options: [.colorSpace: workingColorSpace])
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
