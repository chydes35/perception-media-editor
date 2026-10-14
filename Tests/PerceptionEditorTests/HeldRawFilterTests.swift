import CoreGraphics
import Darwin
import CoreImage
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

    /// The held filter, mutated through as-shot, a temperature edit, a tint edit and a return to as-shot,
    /// must render like a filter built from scratch with the same settings.
    @Test(.enabled(if: HeldRawFilterTests.path != nil)) func mutatedFilterMatchesAFilterBuiltFromScratch() async throws {
        let url = URL(fileURLWithPath: try #require(Self.path))
        let renderer = PhotoRenderer()
        let info = try #require(await renderer.rawInfo(url: url))
        let context = CIContext()
        func render(_ image: CIImage) throws -> CGImage {
            let scaled = image.transformed(by: CGAffineTransform(scaleX: 200 / image.extent.width, y: 200 / image.extent.width))
            return try #require(context.createCGImage(scaled, from: scaled.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)))
        }
        var cool = RawSettings(); cool.temperature = info.asShotTemperature - 900
        var tinted = cool; tinted.tint = 35
        var warmOnly = RawSettings(); warmOnly.temperature = info.asShotTemperature + 700
        let steps: [RawSettings] = [RawSettings(), cool, tinted, cool, RawSettings(), warmOnly]
        for settings in steps {
            let held = try #require(await renderer.heldDecodeThumbnail(url: url, raw: settings, width: 200))
            let scratch = try #require(PhotoSourceLoader.load(url, maxDimension: PhotoRenderer.workingDimension, raw: settings))
            #expect(maxDiff(held, try render(scratch)) <= 1, "settings \(settings.cacheKey)")
        }
    }

    /// Time from opening a photo (as-shot preview) to the first white balance tick, then later ticks.
    @Test(.enabled(if: HeldRawFilterTests.path != nil)) func firstTickAfterOpeningIsFast() async throws {
        let url = URL(fileURLWithPath: try #require(Self.path))
        func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
        var first: [Double] = [], later: [Double] = []
        for _ in 0 ..< 5 {
            let renderer = PhotoRenderer()
            let info = try #require(await renderer.rawInfo(url: url))
            _ = try #require(await renderer.preview(url: url, adjustments: .neutral))
            for i in 0 ..< 4 {
                let start = ContinuousClock.now
                _ = try #require(await renderer.preview(url: url, adjustments: at(info.asShotTemperature - 600 + Double(i) * 120)))
                let elapsed = ms(ContinuousClock.now - start)
                if i == 0 { first.append(elapsed) } else { later.append(elapsed) }
            }
        }
        func line(_ t: [Double]) -> String { t.sorted().map { String(format: "%.0f", $0) }.joined(separator: " ") }
        print("First tick after opening (ms): \(line(first)) | later ticks (ms): \(line(later))")
    }

    private func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    /// Footprint after many white balance ticks with and without the held filter.
    @Test(.enabled(if: HeldRawFilterTests.path != nil)) func heldFilterFootprint() async throws {
        let url = URL(fileURLWithPath: try #require(Self.path))
        var out: [String] = []
        for mode in (ProcessInfo.processInfo.environment["PME_ORDER"] == "held-first" ? ["held", "fresh-per-tick"] : ["fresh-per-tick", "held"]) {
            let renderer = PhotoRenderer()
            let info = try #require(await renderer.rawInfo(url: url))
            let base = footprintMB()
            var peak = base
            for i in 0 ..< 40 {
                let kelvin = info.asShotTemperature - 800 + Double(i % 16) * 110
                if mode == "fresh-per-tick" { await renderer.evictAll() }
                _ = try #require(await renderer.preview(url: url, adjustments: at(kelvin)))
                peak = max(peak, footprintMB())
            }
            out.append("\(mode): start \(Int(base)) MB, peak \(Int(peak)) MB, end \(Int(footprintMB())) MB")
            await renderer.evictAll()
            out.append("\(mode) after evictAll: \(Int(footprintMB())) MB")
        }
        print("Footprint: " + out.joined(separator: " | "))
    }
}
