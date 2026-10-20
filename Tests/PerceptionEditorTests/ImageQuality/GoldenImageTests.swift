import CoreImage
import Foundation
import Testing
@testable import PerceptionEditor

/// Process-version-1 regression: every fixture × recipe must still render to its recorded golden.
/// Goldens are raw little-endian UInt16 RGBA (sRGB-encoded) with an 8-byte width/height header.
/// Regenerate on purpose with `PM_UPDATE_GOLDENS=1`.
struct GoldenImageTests {
    static let goldenDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/Golden", isDirectory: true)

    struct Case: Sendable, CustomTestStringConvertible {
        let fixture: String, recipe: String
        var testDescription: String { "\(fixture)/\(recipe)" }
    }

    static let cases: [Case] = IQFixtures.all.flatMap { fixture in
        IQRecipes.all.map { Case(fixture: fixture.name, recipe: $0.name) }
    }

    static func encode(_ pixels: [UInt16], width: Int, height: Int) -> Data {
        var data = Data()
        withUnsafeBytes(of: UInt32(width).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(height).littleEndian) { data.append(contentsOf: $0) }
        pixels.withUnsafeBufferPointer { buffer in
            for value in buffer { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        }
        return data
    }

    static func decode(_ data: Data) -> (pixels: [UInt16], width: Int, height: Int)? {
        guard data.count >= 8 else { return nil }
        let bytes = [UInt8](data)
        let width = Int(UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24)
        let height = Int(UInt32(bytes[4]) | UInt32(bytes[5]) << 8 | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 24)
        guard bytes.count == 8 + width * height * 8 else { return nil }
        let pixels = stride(from: 8, to: bytes.count, by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 }
        return (pixels, width, height)
    }

    @Test(arguments: cases)
    func rendersMatchTheirGolden(_ testCase: Case) throws {
        let fixture = try #require(IQFixtures.all.first { $0.name == testCase.fixture })
        let recipe = try #require(IQRecipes.all.first { $0.name == testCase.recipe })
        let source = fixture.make()
        let pixels = IQRender.render(source, recipe.adjustments, highlightRolloff: recipe.rolloff)
        let width = Int(source.extent.width), height = Int(source.extent.height)
        let url = Self.goldenDirectory.appendingPathComponent("\(testCase.fixture)__\(testCase.recipe).bin")

        if ProcessInfo.processInfo.environment["PM_UPDATE_GOLDENS"] == "1" {
            try FileManager.default.createDirectory(at: Self.goldenDirectory, withIntermediateDirectories: true)
            try Self.encode(pixels, width: width, height: height).write(to: url, options: .atomic)
            return
        }

        let stored = try #require(try? Data(contentsOf: url), "missing golden \(url.lastPathComponent); run with PM_UPDATE_GOLDENS=1")
        let golden = try #require(Self.decode(stored), "corrupt golden \(url.lastPathComponent)")
        #expect(golden.width == width && golden.height == height)
        let summary = IQMetrics.compare(golden.pixels, pixels)
        // GPU rounding can differ by a code value or two between chips; anything visible is a regression.
        #expect(summary.maxCodeDifference <= 64, "max code difference \(summary.maxCodeDifference)")
        #expect(summary.meanDeltaE < 0.05, "mean ΔE2000 \(summary.meanDeltaE)")
        #expect(summary.maxDeltaE < 1.0, "max ΔE2000 \(summary.maxDeltaE)")
    }
}

struct IQMetricsTests {
    @Test func identicalBuffersAreIdentical() {
        let buffer = IQRender.pixels(of: IQFixtures.colorChecker())
        let summary = IQMetrics.compare(buffer, buffer)
        #expect(summary.maxDeltaE == 0 && summary.maxCodeDifference == 0)
        #expect(IQMetrics.ssimLuma(buffer, buffer) > 0.9999)
    }

    @Test func deltaE2000MatchesPublishedReferencePairs() {
        // Sharma, Wu, Dalal (2005) test data, pairs 1 and 5.
        let one = IQMetrics.deltaE2000((50.0, 2.6772, -79.7751), (50.0, 0.0, -82.7485))
        #expect(abs(one - 2.0425) < 0.001)
        let five = IQMetrics.deltaE2000((50.0, 2.5, 0.0), (73.0, 25.0, -18.0))
        #expect(abs(five - 27.1492) < 0.001)
    }

    @Test func oklchHueOfPrimariesIsKnown() {
        let red = IQMetrics.oklch(fromLinear: 1, 0, 0)
        #expect(abs(red.h - 29.2) < 0.5)
        let blue = IQMetrics.oklch(fromLinear: 0, 0, 1)
        #expect(abs(blue.h - 264.1) < 0.5)
    }

    @Test func hueDifferenceWrapsAround() {
        #expect(IQMetrics.hueDifference(359, 1) == 2)
    }
}
