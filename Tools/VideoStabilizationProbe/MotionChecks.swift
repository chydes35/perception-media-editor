// Standalone checks: compile with Motion.swift, without SwiftUI or the app.
import Foundation
import CoreGraphics
import CoreMedia

@main struct MotionChecks {
    static func main() {
        func samples(_ xs: [Double], times: [Double]? = nil, segment: Int = 0) -> [MotionSample] {
            xs.enumerated().map { i, x in
                let t = CMTime(seconds: times?[i] ?? Double(i) / 24, preferredTimescale: 24000)
                return MotionSample(value: t.value, timescale: t.timescale, segment: segment,
                                    path: Pose(x: x), confidence: 1, valid: true)
            }
        }
        let stationary = samples(Array(repeating: 0, count: 48))
        assert(MotionMath.corrections(stationary, radius: 0.5, strength: 1).allSatisfy { $0.x == 0 })
        let jitter = samples((0..<48).map { $0.isMultiple(of: 2) ? -8 : 8 })
        let correction = MotionMath.corrections(jitter, radius: 0.5, strength: 1)
        let residual = zip(jitter, correction).map { $0.path.x + $1.x }
        let rms = sqrt(residual.map { $0 * $0 }.reduce(0, +) / Double(residual.count))
        assert(rms < 5.6, "Alternating jitter must fall by at least 30%; got \(rms)")
        assert(MotionMath.corrections(jitter, radius: 0.5, strength: 0).allSatisfy { $0.x == 0 })
        assert(MotionMath.corrections(jitter, radius: 0.5, strength: .nan).allSatisfy { $0.x == 0 })
        var failed = samples([0, 10000, 0])
        failed[1].valid = false
        assert(MotionMath.corrections(failed, radius: 0.5, strength: 1).allSatisfy { $0.x == 0 },
               "Rejected motion cannot influence neighboring corrections")
        let irregular = [0.0, 0.04, 0.10, 0.15, 0.22, 0.30, 0.39]
        let pan = samples(irregular.map { 30 * $0 + 2 }, times: irregular)
        assert(MotionMath.corrections(pan, radius: 0.5, strength: 1).allSatisfy { abs($0.x) < 1e-8 },
               "A time-linear pan including endpoints must be preserved")
        let cut = samples([0, 0, 0]) + samples([100, 100, 100], segment: 1)
        assert(MotionMath.corrections(cut, radius: 0.5, strength: 1).allSatisfy { abs($0.x) < 1e-8 })
        let rotated = [Pose(x: 15, y: -10, angle: 0.08), Pose(x: -9, y: 3, angle: -0.05)]
        let zoom = MotionMath.requiredZoom(rotated, width: 640, height: 360)
        assert(zoom > 1)
        for pose in rotated {
            let inverse = MotionMath.transform(pose, width: 640, height: 360, zoom: zoom).inverted()
            for corner in [CGPoint(x: 0,y: 0), CGPoint(x: 640,y: 0), CGPoint(x: 0,y: 360), CGPoint(x: 640,y: 360)] {
                let p = corner.applying(inverse)
                assert(p.x >= -1e-6 && p.x <= 640.000001 && p.y >= -1e-6 && p.y <= 360.000001,
                       "Auto crop must cover every output corner")
            }
        }
        let turn = CGPoint(x: 420, y: 180).applying(MotionMath.transform(Pose(angle: .pi/2), width: 640, height: 360, zoom: 1))
        assert(abs(turn.x - 320) < 1e-8 && abs(turn.y - 280) < 1e-8, "Rotation is counterclockwise radians")
        let source = MotionMath.sourceTime(timeline: CMTime(value: 130, timescale: 24),
                                          timelineStart: CMTime(value: 120, timescale: 24),
                                          sourceStart: CMTime(value: 25, timescale: 30))
        assert(CMTimeCompare(source, CMTime(value: 5, timescale: 4)) == 0)
        print("PASS: identity, ≥30% jitter reduction, strength zero, irregular-PTS pan/endpoints, segment isolation, crop containment, rotation sign/radians, rational clip mapping")
    }
}
