// Development-only experiment. Not compiled into PerceptionEditor.
import Foundation
import CoreGraphics
import CoreMedia

struct Pose: Codable {
    var x = 0.0
    var y = 0.0
    var angle = 0.0
}

struct MotionSample: Codable {
    var value: Int64
    var timescale: Int32
    var segment: Int
    var path: Pose
    var confidence: Float
    var valid: Bool
    var seconds: Double { CMTime(value: value, timescale: timescale).seconds }
}

enum MotionMath {
    static func corrections(_ samples: [MotionSample], radius: Double, strength: Double) -> [Pose] {
        guard radius.isFinite, radius > 0, strength.isFinite else { return samples.map { _ in Pose() } }
        let amount = min(1, max(0, strength))
        return samples.map { center in
            guard center.valid else { return Pose() }
            // Local linear regression preserves sustained pans, including at endpoints,
            // and operates on actual PTS rather than nominal frame indices.
            var w = 0.0, wt = 0.0, wtt = 0.0
            var sums = [Double](repeating: 0, count: 3)
            var slopes = sums
            for sample in samples where sample.valid && sample.segment == center.segment {
                let dt = sample.seconds - center.seconds
                guard abs(dt) <= radius else { continue }
                let weight = exp(-2 * dt * dt / (radius * radius))
                let values = [sample.path.x, sample.path.y, sample.path.angle]
                guard values.allSatisfy(\.isFinite) else { continue }
                w += weight; wt += weight * dt; wtt += weight * dt * dt
                for k in 0..<3 { sums[k] += weight * values[k]; slopes[k] += weight * dt * values[k] }
            }
            guard w > 0 else { return Pose() }
            let denominator = w * wtt - wt * wt
            let current = [center.path.x, center.path.y, center.path.angle]
            let corrected = (0..<3).map { k -> Double in
                let smooth = denominator > 1e-12 ? (sums[k] * wtt - slopes[k] * wt) / denominator : sums[k] / w
                let value = amount * (smooth - current[k])
                return value.isFinite ? value : 0
            }
            return Pose(x: corrected[0], y: corrected[1], angle: corrected[2])
        }
    }

    static func transform(_ pose: Pose, width: Double, height: Double, zoom: Double) -> CGAffineTransform {
        let c = cos(pose.angle), s = sin(pose.angle)
        let cx = width / 2, cy = height / 2
        return CGAffineTransform(a: zoom * c, b: zoom * s, c: -zoom * s, d: zoom * c,
                                 tx: cx + zoom * (pose.x - c * cx + s * cy),
                                 ty: cy + zoom * (pose.y - s * cx - c * cy))
    }

    static func requiredZoom(_ poses: [Pose], width: Double, height: Double) -> Double {
        var result = 1.0
        for pose in poses {
            let c = cos(pose.angle), s = sin(pose.angle)
            let dx = abs(c * pose.x + s * pose.y), dy = abs(-s * pose.x + c * pose.y)
            guard width > 2 * dx, height > 2 * dy else { return .infinity }
            result = max(result, (abs(c) * width + abs(s) * height) / (width - 2 * dx),
                         (abs(s) * width + abs(c) * height) / (height - 2 * dy))
        }
        return result
    }

    static func sourceTime(timeline: CMTime, timelineStart: CMTime, sourceStart: CMTime) -> CMTime {
        CMTimeAdd(sourceStart, CMTimeSubtract(timeline, timelineStart))
    }
}
