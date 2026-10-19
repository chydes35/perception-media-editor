import CoreGraphics
import Foundation
@preconcurrency import Vision

/// Every tunable Look Match limit in one place. Defaults are starting values chosen before
/// tuning on a real family-portrait shoot; plans/active/look-match-agent.md records their basis.
struct LookMatchThresholds: Sendable, Equatable {
    /// A pause longer than this between consecutive frames starts a new scene.
    var captureGapSeconds = 180.0
    /// As-shot white balance change, in mired, that starts a new scene.
    var miredStep = 20.0
    /// Scene exposure value change (ISO 100 EV) that starts a new scene.
    var exposureStep = 1.0
    /// Euclidean distance between unit-length Vision feature prints that starts a new scene.
    var featurePrintDistance = 0.9
    /// Proposals below this confidence are flagged and left unselected.
    var minimumConfidence = 0.6
    /// Exposure may move at most this far from the hero's value.
    var maximumExposureOffset = 1.5
    /// Highlights and shadows may move at most this far from the hero's values.
    var maximumToneNudge = 0.25
    /// Percentile difference (sRGB-encoded luma) below which highlights/shadows are left alone.
    var percentileTolerance = 0.03

    static let `default` = LookMatchThresholds()
}

/// What scene grouping knows about one photo. Missing values never split a scene.
struct SceneSignal: Sendable, Equatable {
    var assetID: UUID
    var captureDate: Date?
    var asShotMired: Double?
    var exposureValue: Double?
    /// Unit-length Vision feature print.
    var featurePrint: [Float]?
}

enum LookMatchScenes {
    /// Photos in capture order. Undated photos follow dated ones; ties keep the input order.
    static func ordered(_ signals: [SceneSignal]) -> [SceneSignal] {
        signals.enumerated().sorted { a, b in
            switch (a.element.captureDate, b.element.captureDate) {
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }

    /// Groups photos into lighting scenes. A new scene starts when any signal between
    /// consecutive photos (in capture order) exceeds its threshold. Deterministic.
    static func group(_ signals: [SceneSignal], thresholds: LookMatchThresholds) -> [[UUID]] {
        var scenes: [[UUID]] = []
        var previous: SceneSignal?
        for signal in ordered(signals) {
            if let previous, !startsNewScene(previous, signal, thresholds: thresholds) {
                scenes[scenes.count - 1].append(signal.assetID)
            } else {
                scenes.append([signal.assetID])
            }
            previous = signal
        }
        return scenes
    }

    static func startsNewScene(_ a: SceneSignal, _ b: SceneSignal, thresholds: LookMatchThresholds) -> Bool {
        if let x = a.captureDate, let y = b.captureDate,
           abs(y.timeIntervalSince(x)) > thresholds.captureGapSeconds { return true }
        if let x = a.asShotMired, let y = b.asShotMired, abs(x - y) > thresholds.miredStep { return true }
        if let x = a.exposureValue, let y = b.exposureValue, abs(x - y) > thresholds.exposureStep { return true }
        if let distance = featureDistance(a.featurePrint, b.featurePrint),
           distance > thresholds.featurePrintDistance { return true }
        return false
    }

    static func featureDistance(_ a: [Float]?, _ b: [Float]?) -> Double? {
        guard let a, let b, a.count == b.count, !a.isEmpty else { return nil }
        var sum = 0.0
        for index in a.indices {
            let difference = Double(a[index] - b[index])
            sum += difference * difference
        }
        return sum.squareRoot()
    }

    /// How many look groups (everything but white balance) differ from an untouched photo.
    /// Brush strokes, retouches and geometry do not count.
    static func lookGroupCount(_ adjustments: PhotoAdjustments?) -> Int {
        (adjustments ?? .neutral).editedGroups.intersection(AdjustmentGroup.looks).count
    }

    /// The selected photo when it is in the scene and edited; otherwise the photo with the most
    /// edited look groups (ties: latest capture, then later in capture order). Nil when no photo
    /// in the scene has a look edit.
    static func hero(
        in scene: [UUID],
        adjustments: [UUID: PhotoAdjustments],
        selectedID: UUID?,
        captureDates: [UUID: Date]
    ) -> UUID? {
        if let selectedID, scene.contains(selectedID), lookGroupCount(adjustments[selectedID]) > 0 {
            return selectedID
        }
        let edited = scene.enumerated().filter { lookGroupCount(adjustments[$0.element]) > 0 }
        return edited.max { a, b in
            let countA = lookGroupCount(adjustments[a.element]), countB = lookGroupCount(adjustments[b.element])
            if countA != countB { return countA < countB }
            let dateA = captureDates[a.element] ?? .distantPast, dateB = captureDates[b.element] ?? .distantPast
            if dateA != dateB { return dateA < dateB }
            return a.offset < b.offset
        }?.element
    }

    /// A unit-length Vision feature print of an image, or nil when Vision returns none.
    static func featurePrint(of image: CGImage) throws -> [Float]? {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first as? VNFeaturePrintObservation,
              observation.elementCount > 0 else { return nil }
        let values: [Float]
        switch observation.elementType {
        case .float:
            values = observation.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(observation.elementCount)) }
        case .double:
            values = observation.data.withUnsafeBytes {
                $0.bindMemory(to: Double.self).prefix(observation.elementCount).map { Float($0) }
            }
        default:
            return nil
        }
        let length = values.reduce(0) { $0 + Double($1) * Double($1) }.squareRoot()
        guard length > 0, length.isFinite else { return nil }
        return values.map { Float(Double($0) / length) }
    }
}
