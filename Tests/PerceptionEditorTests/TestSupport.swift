import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// An exact sRGB color. `CGColor(red:green:blue:alpha:)` uses Apple's generic RGB space,
/// which shifts pure red to (255, 38, 0) once it is drawn into an sRGB image.
func srgbColor(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
    CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [r, g, b, 1])!
}

/// Deletes its directory when released, so tests clean up even when an expectation fails.
final class TempDirectory: @unchecked Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pme-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        // Some tests make directories read-only; restore access so removal works.
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
            for case let child as URL in enumerator {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: child.path)
            }
        }
        try? FileManager.default.removeItem(at: url)
    }

    func subdirectory(_ path: String) throws -> URL {
        let directory = url.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Writes a file of deterministic pseudo-random bytes.
    @discardableResult
    func file(_ path: String, bytes: Int, seed: UInt8 = 1, modified: Date? = nil) throws -> URL {
        let target = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var generator = SeededGenerator(seed: UInt64(seed) &* 0x9E37_79B9_7F4A_7C15 &+ 1)
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { buffer in
            for index in 0 ..< buffer.count { buffer[index] = UInt8.random(in: 0 ... 255, using: &generator) }
        }
        try data.write(to: target)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: target.path)
        }
        return target
    }
}

struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

/// Writes a gradient JPEG, optionally with an EXIF capture date.
@discardableResult
func writeTestJPEG(
    to url: URL,
    width: Int = 400,
    height: Int = 300,
    captureDate: String? = nil
) throws -> URL {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    let gradient = try #require(CGGradient(
        colorsSpace: space,
        colors: [srgbColor(0.1, 0.2, 0.8), srgbColor(0.9, 0.6, 0.1)] as CFArray,
        locations: nil
    ))
    context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
    let image = try #require(context.makeImage())

    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
    var properties: [CFString: Any] = [:]
    if let captureDate {
        properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: captureDate]
    }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return url
}

/// Collects values from `@Sendable` callbacks.
final class Collector<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    func add(_ value: Value) {
        lock.lock(); defer { lock.unlock() }
        storage.append(value)
    }

    var values: [Value] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

/// A PNG whose quadrants are red (top-left), green (top-right), blue (bottom-left), and
/// yellow (bottom-right), for checking that positions map to the right pixels.
@discardableResult
func writeQuadrantPNG(to url: URL, width: Int = 800, height: Int = 600) throws -> URL {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    let halfW = CGFloat(width) / 2, halfH = CGFloat(height) / 2
    // CGContext's origin is the bottom-left corner.
    context.setFillColor(srgbColor(1, 0, 0))
    context.fill(CGRect(x: 0, y: halfH, width: halfW, height: halfH))
    context.setFillColor(srgbColor(0, 1, 0))
    context.fill(CGRect(x: halfW, y: halfH, width: halfW, height: halfH))
    context.setFillColor(srgbColor(0, 0, 1))
    context.fill(CGRect(x: 0, y: 0, width: halfW, height: halfH))
    context.setFillColor(srgbColor(1, 1, 0))
    context.fill(CGRect(x: halfW, y: 0, width: halfW, height: halfH))
    let image = try #require(context.makeImage())

    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return url
}

/// The color of one pixel of `image`, counted from its top-left corner.
func pixel(of image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
    var data = [UInt8](repeating: 0, count: 4)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    data.withUnsafeMutableBytes { buffer in
        let context = CGContext(
            data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // Draw so that pixel (x, y) from the top-left lands on the single output pixel.
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    }
    return (Int(data[0]), Int(data[1]), Int(data[2]))
}

/// Polls until `condition` holds, or fails the test after `timeout` seconds.
@MainActor
func waitUntil(timeout: Double = 15, _ condition: @MainActor () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline {
            Issue.record("Timed out waiting for a condition")
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}

/// A real RAW file for tests that need one. They run where the Lumix S5 samples are available
/// (set PME_RAW_SAMPLES to a folder of .RW2 files) and are skipped elsewhere, such as in CI.
enum RawSample {
    static let url: URL? = {
        let directory = ProcessInfo.processInfo.environment["PME_RAW_SAMPLES"] ?? "/Volumes/ExSSD1/110_PANA"
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory))?
            .filter { $0.uppercased().hasSuffix(".RW2") }
            .sorted()
        return files?.first.map { URL(fileURLWithPath: directory).appendingPathComponent($0) }
    }()

    static var isAvailable: Bool { url != nil }
}
