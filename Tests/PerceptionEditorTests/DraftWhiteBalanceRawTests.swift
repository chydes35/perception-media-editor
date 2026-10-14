import CoreGraphics
import Foundation
import Testing
@testable import PerceptionEditor

/// Opt-in: set PME_WB_RAW to a copy of a RAW file. Exercises the draft path through the real renderer.
struct DraftWhiteBalanceRawTests {
    private static let path = ProcessInfo.processInfo.environment["PME_WB_RAW"]

    private func meanAbsDiff(_ a: CGImage, _ b: CGImage) -> Double {
        func pixels(_ image: CGImage, _ w: Int, _ h: Int) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: w * h * 4)
            data.withUnsafeMutableBytes { buffer in
                let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            return data
        }
        let w = 400, h = 267
        let (pa, pb) = (pixels(a, w, h), pixels(b, w, h))
        var total = 0.0
        for i in stride(from: 0, to: pa.count, by: 4) { for c in 0 ..< 3 { total += abs(Double(pa[i + c]) - Double(pb[i + c])) } }
        return total / Double(w * h * 3)
    }

    @Test(.enabled(if: DraftWhiteBalanceRawTests.path != nil)) func draftIsUsedOnlyWhenNoExactDecodeIsCached() async throws {
        let url = URL(fileURLWithPath: try #require(Self.path))
        let renderer = PhotoRenderer()
        let info = try #require(await renderer.rawInfo(url: url))
        func at(_ kelvin: Double) -> PhotoAdjustments { var a = PhotoAdjustments.neutral; a.raw.temperature = kelvin; return a }

        // Without the as-shot decode cached there is nothing to shift.
        let cold = try #require(await renderer.preview(url: url, adjustments: at(info.asShotTemperature + 1500), allowsDraft: true))
        #expect(!cold.isDraft)

        // Cache the as-shot decode, then a draft is possible.
        _ = try #require(await renderer.preview(url: url, adjustments: .neutral))
        let target = info.asShotTemperature - 1200
        let clock = ContinuousClock.now
        let draft = try #require(await renderer.preview(url: url, adjustments: at(target), allowsDraft: true))
        let draftTime = ContinuousClock.now - clock
        #expect(draft.isDraft)

        // Steady state: further ticks reuse compiled kernels.
        var ticks: [Double] = []
        for i in 1 ... 12 {
            let start = ContinuousClock.now
            let tick = try #require(await renderer.preview(url: url, adjustments: at(info.asShotTemperature - 1200 + Double(i) * 40), allowsDraft: true))
            let d = ContinuousClock.now - start
            ticks.append(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
            #expect(tick.isDraft)
        }
        print("Draft ticks after warm-up (ms): \(ticks.sorted().map { String(format: "%.0f", $0) }.joined(separator: " "))")

        // Not allowed: exact. Then the exact decode is cached, so even a draft request returns exact pixels.
        let exact = try #require(await renderer.preview(url: url, adjustments: at(target), allowsDraft: false))
        #expect(!exact.isDraft)
        let again = try #require(await renderer.preview(url: url, adjustments: at(target), allowsDraft: true))
        #expect(!again.isDraft)

        let error = meanAbsDiff(draft.edited.cgImage, exact.edited.cgImage)
        print("Draft white balance, \(Int(target)) K from as-shot \(Int(info.asShotTemperature)) K: draft preview \(draftTime), mean error versus exact \(String(format: "%.1f", error))/255")
        #expect(error < 12)

        // Tint or another RAW setting forces the exact path.
        var tinted = at(target + 100); tinted.raw.tint = 5
        let withTint = try #require(await renderer.preview(url: url, adjustments: tinted, allowsDraft: true))
        #expect(!withTint.isDraft)
    }
}
