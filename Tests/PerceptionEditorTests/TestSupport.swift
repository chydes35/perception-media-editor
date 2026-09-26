import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

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
        colors: [CGColor(red: 0.1, green: 0.2, blue: 0.8, alpha: 1), CGColor(red: 0.9, green: 0.6, blue: 0.1, alpha: 1)] as CFArray,
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
