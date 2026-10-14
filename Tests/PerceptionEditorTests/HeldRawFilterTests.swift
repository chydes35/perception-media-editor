import CoreGraphics
import Foundation
import Testing
@testable import PerceptionEditor

/// Opt-in: set PME_WB_RAW to a copy of a RAW file. A held filter must render the same pixels as a fresh one.
struct HeldRawFilterTests {
    private static let path = ProcessInfo.processInfo.environment["PME_WB_RAW"]

    private func at(_ kelvin: Double, tint: Double? = nil) -> PhotoAdjustments {
        var a = PhotoAdjustments.neutral
        a.raw.temperature = kelvin
        a.raw.tint = tint
        return a
    }

    private func pixels(_ image: CGImage) -> [UInt8] {
        let w = 200, h = 133
        var data = [UInt8](repeating: 0, count: w * h * 4)
        data.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return data
    }

    private func maxDiff(_ a: CGImage, _ b: CGImage) -> Int {
        zip(pixels(a), pixels(b)).map { abs(Int($0) - Int($1)) }.max() ?? 0
    }

    @Test(.enabled(if: HeldRawFilterTests.path != nil)) func reusedFilterMatchesAFreshDecode() async throws {
        let url = URL(fileURLWithPath: try #require(Self.path))
        let held = PhotoRenderer(memoryTargetMB: Int(ProcessInfo.processInfo.environment["PME_MEM_MB"] ?? "256"))
        let info = try #require(await held.rawInfo(url: url))
        let temperatures = (0 ..< 16).map { info.asShotTemperature - 800 + Double($0) * 110 }

        func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
        var reusedTimes: [Double] = [], freshTimes: [Double] = []
        var reusedImages: [CGImage] = [], freshImages: [CGImage] = []
        for kelvin in temperatures {
            let start = ContinuousClock.now
            reusedImages.append(try #require(await held.preview(url: url, adjustments: at(kelvin))).edited.cgImage)
            reusedTimes.append(ms(ContinuousClock.now - start))
        }
        for kelvin in temperatures {
            let renderer = PhotoRenderer()
            _ = await renderer.rawInfo(url: url)
            let start = ContinuousClock.now
            freshImages.append(try #require(await renderer.preview(url: url, adjustments: at(kelvin))).edited.cgImage)
            freshTimes.append(ms(ContinuousClock.now - start))
        }
        for (a, b) in zip(reusedImages, freshImages) { #expect(maxDiff(a, b) <= 1) }
        func line(_ t: [Double]) -> String { t.dropFirst().sorted().map { String(format: "%.0f", $0) }.joined(separator: " ") }
        print("Held-filter exact renders (ms): \(line(reusedTimes)) | fresh renderer each (ms): \(line(freshTimes))")

        // Tint going back to unset must not keep the old tint.
        _ = try #require(await held.preview(url: url, adjustments: at(temperatures[0], tint: 40)))
        let back = try #require(await held.preview(url: url, adjustments: at(temperatures[0])))
        let fresh = try #require(await PhotoRenderer().preview(url: url, adjustments: at(temperatures[0])))
        #expect(maxDiff(back.edited.cgImage, fresh.edited.cgImage) <= 1)
    }
}
