import Foundation
import Testing
@testable import PerceptionEditor

struct SubjectEdgeMattingTests {
    private let w = 96, h = 64

    /// Left 40 columns are a red subject on a blue background; the model mask is too soft at the
    /// boundary and misses a thin red wisp that sticks out into the background.
    private func scene(subject: [Float] = [0.9, 0.1, 0.1], background: [Float] = [0.1, 0.1, 0.9])
        -> (rgb: [Float], mask: [Float]) {
        var rgb = [Float](repeating: 0, count: w * h * 3), mask = [Float](repeating: 0, count: w * h)
        for y in 0 ..< h {
            for x in 0 ..< w {
                let inSubject = x < 40 || ((29 ... 31).contains(y) && x < 52)   // wisp: three rows, 12 px long
                let color = inSubject ? subject : background
                for c in 0 ..< 3 { rgb[(y * w + x) * 3 + c] = color[c] }
                // Model mask: sharp interior, ramp across the true edge, no wisp.
                mask[y * w + x] = x < 36 ? 1 : (x < 44 ? Float(44 - x) / 8 : 0)
            }
        }
        return (rgb, mask)
    }

    @Test func wispOutsideTheModelMaskIsRecovered() {
        let (rgb, mask) = scene()
        var wide = SubjectEdgeMatting.Parameters()
        wide.band = 20                         // the wisp reaches 16 px past the certain subject
        let out = SubjectEdgeMatting.refine(mask: mask, rgb: rgb, width: w, height: h, parameters: wide)
        #expect(mask[30 * w + 47] == 0)
        #expect(out[30 * w + 47] > 0.8)        // on the wisp
        #expect(out[20 * w + 47] < 0.1)        // background beside the wisp
    }

    @Test func softBoundarySnapsToTheColorEdge() {
        let (rgb, mask) = scene()
        let out = SubjectEdgeMatting.refine(mask: mask, rgb: rgb, width: w, height: h)
        #expect(out[10 * w + 38] > 0.9)        // still subject color, model said 0.25
        #expect(out[10 * w + 42] < 0.1)        // background color, model said 0.25
    }

    @Test func certainRegionsAreNeverChanged() {
        let (rgb, mask) = scene()
        let out = SubjectEdgeMatting.refine(mask: mask, rgb: rgb, width: w, height: h)
        for y in 0 ..< h {
            for x in 0 ..< w where mask[y * w + x] >= 0.97 || mask[y * w + x] <= 0.03 {
                if ((28 ... 32).contains(y) && x >= 40 && x < 56) { continue }   // the wisp lies in the band
                // Background beside the subject is re-estimated, but pure background stays at zero.
                #expect(abs(out[y * w + x] - mask[y * w + x]) < 0.02)
            }
        }
    }

    @Test func similarColorsKeepTheModelMask() {
        let (rgb, mask) = scene(subject: [0.5, 0.5, 0.5], background: [0.52, 0.5, 0.5])
        let out = SubjectEdgeMatting.refine(mask: mask, rgb: rgb, width: w, height: h)
        #expect(out == mask)
    }

    @Test func mismatchedInputsAreReturnedUnchanged() {
        let mask = [Float](repeating: 0.5, count: 10)
        #expect(SubjectEdgeMatting.refine(mask: mask, rgb: [0], width: 5, height: 2) == mask)
    }
}
