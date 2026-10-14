import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
@testable import PerceptionEditor

struct WhiteBalanceShiftTests {
    private func close(_ a: WhiteBalanceShift.Matrix, _ b: WhiteBalanceShift.Matrix, tolerance: Double = 1e-9) -> Bool {
        zip(a.joined(), b.joined()).allSatisfy { abs($0 - $1) < tolerance }
    }

    @Test func noChangeIsTheIdentity() {
        #expect(close(WhiteBalanceShift.matrix(from: 5200, to: 5200), WhiteBalanceShift.identity))
    }

    @Test func shiftingThereAndBackIsTheIdentity() {
        let there = WhiteBalanceShift.matrix(from: 4100, to: 6500)
        let back = WhiteBalanceShift.matrix(from: 6500, to: 4100)
        #expect(close(WhiteBalanceShift.multiply(back, there), WhiteBalanceShift.identity, tolerance: 1e-9))
    }

    /// A lower temperature means a warmer assumed light, so the picture turns bluer; higher turns it warmer.
    @Test func lowerTemperatureMakesGrayBluerAndHigherMakesItWarmer() {
        func gray(_ m: WhiteBalanceShift.Matrix) -> (r: Double, b: Double) {
            (m[0].reduce(0, +), m[2].reduce(0, +))   // response to (1, 1, 1)
        }
        let cooler = gray(WhiteBalanceShift.matrix(from: 5200, to: 3500))
        let warmer = gray(WhiteBalanceShift.matrix(from: 5200, to: 8000))
        #expect(cooler.b / cooler.r > 1.05)
        #expect(warmer.b / warmer.r < 0.95)
    }

    @Test func largerChangesMoveFurther() {
        func blueRed(_ target: Double) -> Double {
            let m = WhiteBalanceShift.matrix(from: 5200, to: target)
            return m[2].reduce(0, +) / m[0].reduce(0, +)
        }
        #expect(blueRed(3000) > blueRed(4000))
        #expect(blueRed(4000) > blueRed(5000))
    }

    @Test func onlyATemperatureChangeOnDefaultRawSettingsCanBeShifted() {
        var raw = RawSettings()
        #expect(!WhiteBalanceShift.canShift(raw))                // nothing to shift
        raw.temperature = 4800
        #expect(WhiteBalanceShift.canShift(raw))
        var tinted = raw; tinted.tint = 10
        #expect(!WhiteBalanceShift.canShift(tinted))             // tint is not modeled
        var denoised = raw; denoised.luminanceNoiseReduction = 0.5
        #expect(!WhiteBalanceShift.canShift(denoised))           // needs its own decode
        var lens = raw; lens.lensCorrection = false
        #expect(!WhiteBalanceShift.canShift(lens))
    }

    @Test func applyingTheShiftChangesPixelsTheWayTheMatrixSays() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let source = CIImage(color: CIColor(red: 0.4, green: 0.4, blue: 0.4, colorSpace: space)!).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        let shifted = WhiteBalanceShift.apply(to: source, from: 5200, to: 3200)
        var pixel = [Float](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space])
        context.render(shifted, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: space)
        let m = WhiteBalanceShift.matrix(from: 5200, to: 3200)
        #expect(abs(Double(pixel[0]) - 0.4 * m[0].reduce(0, +)) < 0.01)
        #expect(abs(Double(pixel[2]) - 0.4 * m[2].reduce(0, +)) < 0.01)
        #expect(pixel[2] > pixel[0])
    }
}
