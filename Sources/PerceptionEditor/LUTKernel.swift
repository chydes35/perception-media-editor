import CoreImage
import Foundation

/// Applies a `.cube` LUT inside Core Image's graph: tetrahedral interpolation for 3D tables (the
/// same as `CubeLUT.evaluate` and ffmpeg's `lut3d=interp=tetrahedral`), linear per channel for 1D,
/// with the table's domain and an intensity blend. It is a Core Image kernel, like HSL, so it runs
/// in order with everything else on the command buffer, for photos, graded clips and the video
/// compositor's source-color input alike.
///
/// The table is a small image with no color space (so Core Image never converts its values):
/// a 3D table of n points is n² wide and n tall, lattice point (r, g, b) at x = r + g·n, y = b;
/// a 1D table wraps into rows of at most 4096 entries.
enum LUTKernel {
    private final class Compiled: @unchecked Sendable {
        let threeD = CIKernel(source: LUTKernel.threeDSource)
        let oneD = CIKernel(source: LUTKernel.oneDSource)
    }
    private static let compiled = Compiled()
    static let oneDRowWidth = 4096

    static var isAvailable: Bool { compiled.threeD != nil && compiled.oneD != nil }

    /// `image` must already be in the encoding the LUT expects. Returns `image` itself when the
    /// intensity is 0, and nil when the kernel cannot run.
    static func apply(_ lut: CubeLUT, cacheKey: String?, intensity: Double, to image: CIImage) -> CIImage? {
        guard intensity > 0 else { return image }
        let table = tableImage(for: lut, cacheKey: cacheKey)
        let scale = SIMD3<Float>(repeating: 1) / (lut.domainMax - lut.domainMin)
        let domainMin = CIVector(x: CGFloat(lut.domainMin.x), y: CGFloat(lut.domainMin.y), z: CGFloat(lut.domainMin.z))
        let domainScale = CIVector(x: CGFloat(scale.x), y: CGFloat(scale.y), z: CGFloat(scale.z))
        let tableExtent = table.extent
        let roi: CIKernelROICallback = { index, rect in index == 0 ? rect : tableExtent }
        switch lut.kind {
        case .threeD(let size):
            return compiled.threeD?.apply(extent: image.extent, roiCallback: roi, arguments: [
                image, table, Double(size), domainMin, domainScale, min(1, intensity)
            ])
        case .oneD(let size):
            return compiled.oneD?.apply(extent: image.extent, roiCallback: roi, arguments: [
                image, table, Double(size), Double(min(size, oneDRowWidth)), domainMin, domainScale, min(1, intensity)
            ])
        }
    }

    private final class TableCache: @unchecked Sendable {
        let lock = NSLock()
        var images: [String: CIImage] = [:]
    }
    private static let tables = TableCache()

    static func tableImage(for lut: CubeLUT, cacheKey: String?) -> CIImage {
        if let cacheKey {
            tables.lock.lock()
            let cached = tables.images[cacheKey]
            tables.lock.unlock()
            if let cached { return cached }
        }
        let width: Int, height: Int, count: Int
        switch lut.kind {
        case .threeD(let size): (width, height, count) = (size * size, size, size * size * size)
        case .oneD(let size):
            width = min(size, oneDRowWidth)
            height = (size + width - 1) / width
            count = size
        }
        var data = Data(count: width * height * 16)
        data.withUnsafeMutableBytes { raw in
            let pixels = raw.bindMemory(to: Float.self)
            for entry in 0 ..< count {
                // Bitmap rows run top to bottom; Core Image's y runs bottom to top.
                let x: Int, y: Int
                switch lut.kind {
                case .threeD(let size): (x, y) = (entry % (size * size), entry / (size * size))
                case .oneD: (x, y) = (entry % width, entry / width)
                }
                let pixel = ((height - 1 - y) * width + x) * 4
                pixels[pixel] = lut.values[entry * 3]
                pixels[pixel + 1] = lut.values[entry * 3 + 1]
                pixels[pixel + 2] = lut.values[entry * 3 + 2]
                pixels[pixel + 3] = 1
            }
        }
        let image = CIImage(bitmapData: data, bytesPerRow: width * 16, size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: nil)
            .samplingNearest()
        if let cacheKey {
            tables.lock.lock()
            tables.images[cacheKey] = image
            if tables.images.count > 8 { tables.images.removeValue(forKey: tables.images.keys.first { $0 != cacheKey }!) }
            tables.lock.unlock()
        }
        return image
    }

    private static let threeDSource = """
    vec3 lutEntry(sampler table, float size, vec3 p) {
        return sample(table, samplerTransform(table, vec2(p.r + p.g * size + 0.5, p.b + 0.5))).rgb;
    }

    kernel vec4 applyLUT3D(sampler image, sampler table, float size, vec3 domainMin, vec3 domainScale, float intensity) {
        vec4 c = sample(image, samplerCoord(image));
        vec3 x = clamp((c.rgb - domainMin) * domainScale, 0.0, 1.0) * (size - 1.0);
        vec3 b = min(floor(x), vec3(size - 2.0));
        vec3 f = x - b;
        vec3 c000 = lutEntry(table, size, b);
        vec3 c111 = lutEntry(table, size, b + vec3(1.0));
        vec3 result;
        if (f.r > f.g) {
            if (f.g > f.b) {
                vec3 c100 = lutEntry(table, size, b + vec3(1.0, 0.0, 0.0));
                vec3 c110 = lutEntry(table, size, b + vec3(1.0, 1.0, 0.0));
                result = c000 + (c100 - c000) * f.r + (c110 - c100) * f.g + (c111 - c110) * f.b;
            } else if (f.r > f.b) {
                vec3 c100 = lutEntry(table, size, b + vec3(1.0, 0.0, 0.0));
                vec3 c101 = lutEntry(table, size, b + vec3(1.0, 0.0, 1.0));
                result = c000 + (c100 - c000) * f.r + (c101 - c100) * f.b + (c111 - c101) * f.g;
            } else {
                vec3 c001 = lutEntry(table, size, b + vec3(0.0, 0.0, 1.0));
                vec3 c101 = lutEntry(table, size, b + vec3(1.0, 0.0, 1.0));
                result = c000 + (c001 - c000) * f.b + (c101 - c001) * f.r + (c111 - c101) * f.g;
            }
        } else {
            if (f.b > f.g) {
                vec3 c001 = lutEntry(table, size, b + vec3(0.0, 0.0, 1.0));
                vec3 c011 = lutEntry(table, size, b + vec3(0.0, 1.0, 1.0));
                result = c000 + (c001 - c000) * f.b + (c011 - c001) * f.g + (c111 - c011) * f.r;
            } else if (f.b > f.r) {
                vec3 c010 = lutEntry(table, size, b + vec3(0.0, 1.0, 0.0));
                vec3 c011 = lutEntry(table, size, b + vec3(0.0, 1.0, 1.0));
                result = c000 + (c010 - c000) * f.g + (c011 - c010) * f.b + (c111 - c011) * f.r;
            } else {
                vec3 c010 = lutEntry(table, size, b + vec3(0.0, 1.0, 0.0));
                vec3 c110 = lutEntry(table, size, b + vec3(1.0, 1.0, 0.0));
                result = c000 + (c010 - c000) * f.g + (c110 - c010) * f.r + (c111 - c110) * f.b;
            }
        }
        return vec4(mix(c.rgb, result, intensity), c.a);
    }
    """

    private static let oneDSource = """
    vec3 lutEntry1D(sampler table, float width, float index) {
        return sample(table, samplerTransform(table, vec2(mod(index, width) + 0.5, floor(index / width) + 0.5))).rgb;
    }

    kernel vec4 applyLUT1D(sampler image, sampler table, float size, float width, vec3 domainMin, vec3 domainScale, float intensity) {
        vec4 c = sample(image, samplerCoord(image));
        vec3 x = clamp((c.rgb - domainMin) * domainScale, 0.0, 1.0) * (size - 1.0);
        vec3 i = min(floor(x), vec3(size - 2.0));
        vec3 f = x - i;
        float r = mix(lutEntry1D(table, width, i.r).r, lutEntry1D(table, width, i.r + 1.0).r, f.r);
        float g = mix(lutEntry1D(table, width, i.g).g, lutEntry1D(table, width, i.g + 1.0).g, f.g);
        float bl = mix(lutEntry1D(table, width, i.b).b, lutEntry1D(table, width, i.b + 1.0).b, f.b);
        return vec4(mix(c.rgb, vec3(r, g, bl), intensity), c.a);
    }
    """
}

extension MediaColorRenderer {
    private static let lutEncodingSpace = CGColorSpace(name: CGColorSpace.extendedSRGB)!

    /// A creative LUT expects display-encoded color, so it runs on sRGB-encoded values like HSL.
    /// A LUT that is not loaded (missing file) leaves the image as it is; the store warns about it.
    static func applyCreativeLUT(_ application: LUTApplication, to image: CIImage) -> CIImage {
        guard application.intensity > 0,
              let lut = LoadedLUTs.shared.lut(application.reference.contentHash),
              let encoded = image.matchedFromWorkingSpace(to: lutEncodingSpace),
              let applied = LUTKernel.apply(lut, cacheKey: application.reference.contentHash, intensity: application.intensity, to: encoded),
              let linear = applied.matchedToWorkingSpace(from: lutEncodingSpace) else { return image }
        return linear
    }
}
