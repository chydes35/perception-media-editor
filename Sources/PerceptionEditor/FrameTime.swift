@preconcurrency import AVFoundation
import Foundation

/// A frame rate as an exact frame duration, such as 1001/24000 s for 23.976 fps. Edit points are whole
/// frames in this rate, so cuts never drift the way Double seconds at timescale 600 did (one 23.976
/// frame is 25.025 ticks of 1/600 s).
struct FrameRate: Codable, Hashable, Sendable, CustomStringConvertible {
    /// Seconds per frame are `frameDuration / timescale`.
    var frameDuration: Int64
    var timescale: Int32

    static let ntsc23976 = FrameRate(frameDuration: 1001, timescale: 24000)

    /// Rates cameras actually record. A track's frame duration within 0.05% of one of these is
    /// read as that rate, so odd container timescales (3754/90000) still match 1001/24000.
    static let standardRates: [FrameRate] = [
        .ntsc23976, FrameRate(frameDuration: 1, timescale: 24), FrameRate(frameDuration: 1, timescale: 25),
        FrameRate(frameDuration: 1001, timescale: 30000), FrameRate(frameDuration: 1, timescale: 30),
        FrameRate(frameDuration: 1001, timescale: 48000), FrameRate(frameDuration: 1, timescale: 48),
        FrameRate(frameDuration: 1, timescale: 50), FrameRate(frameDuration: 1001, timescale: 60000),
        FrameRate(frameDuration: 1, timescale: 60), FrameRate(frameDuration: 1001, timescale: 120_000),
        FrameRate(frameDuration: 1, timescale: 120)
    ]

    init(frameDuration: Int64, timescale: Int32) {
        precondition(frameDuration > 0 && timescale > 0, "A frame rate needs a positive frame duration")
        self.frameDuration = frameDuration
        self.timescale = timescale
    }

    /// The rate for a track's minimum frame duration, snapped to a standard rate when it is one.
    init?(frameDuration time: CMTime) {
        guard time.isValid, time.isNumeric, time.value > 0, time.timescale > 0 else { return nil }
        let seconds = time.seconds
        if let standard = Self.standardRates.first(where: { abs($0.frameSeconds - seconds) / $0.frameSeconds < 0.0005 }) {
            self = standard
            return
        }
        let divisor = Self.gcd(time.value, Int64(time.timescale))
        self.init(frameDuration: time.value / divisor, timescale: Int32(Int64(time.timescale) / divisor))
    }

    var frameSeconds: Double { Double(frameDuration) / Double(timescale) }
    var framesPerSecond: Double { Double(timescale) / Double(frameDuration) }
    var frameTime: CMTime { CMTime(value: frameDuration, timescale: timescale) }
    var description: String { String(format: "%.3f fps (%lld/%d)", framesPerSecond, frameDuration, timescale) }

    /// The exact start of frame `frame`, counted from `origin`.
    func time(ofFrame frame: Int64, origin: CMTime = .zero) -> CMTime {
        let offset = CMTime(value: frame * frameDuration, timescale: timescale)
        return origin == .zero ? offset : CMTimeAdd(origin, offset)
    }

    /// The frame showing at `time`: the last frame starting at or before it.
    func frame(containing time: CMTime, origin: CMTime = .zero) -> Int64 {
        let offset = CMTimeConvertScale(CMTimeSubtract(time, origin), timescale: timescale, method: .roundTowardNegativeInfinity)
        return Self.floorDivide(offset.value, frameDuration)
    }

    func seconds(ofFrames frames: Int64) -> Double { Double(frames) * frameSeconds }

    /// Converts seconds to the nearest frame, ties to even. For migration and seconds-based UI input
    /// only; edits themselves stay in frames.
    func nearestFrame(toSeconds seconds: Double) -> Int64 {
        guard seconds.isFinite else { return 0 }
        return Int64((seconds / frameSeconds).rounded(.toNearestOrEven))
    }

    /// A frame count in this rate expressed in `other`'s frames, rounded to the nearest frame.
    func frames(_ count: Int64, in other: FrameRate) -> Int64 {
        if other == self { return count }
        // count · (fd / ts) / (ofd / ots), in exact integer arithmetic where it fits.
        let numerator = count.multipliedReportingOverflow(by: frameDuration * Int64(other.timescale))
        let denominator = Int64(timescale) * other.frameDuration
        guard !numerator.overflow else { return Int64((Double(count) * frameSeconds / other.frameSeconds).rounded()) }
        return (numerator.partialValue * 2 + denominator) / (denominator * 2)
    }

    private static func gcd(_ a: Int64, _ b: Int64) -> Int64 { b == 0 ? abs(a) : gcd(b, a % b) }

    private static func floorDivide(_ a: Int64, _ b: Int64) -> Int64 {
        let quotient = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? quotient - 1 : quotient
    }
}

/// Clip timing from a project saved before schema 11, in seconds. It stays on the clip until the
/// source's real frame rate is known; then the clip is converted to frames and this is cleared.
struct LegacyClipTiming: Codable, Equatable, Sendable {
    var timelineStartSeconds: Double
    var sourceStartSeconds: Double
    var durationSeconds: Double
}
