import CoreGraphics
import ImageIO
import Foundation

/// A click on the photo, in the oriented photo's normalized coordinates (0…1, origin top-left).
struct SegmentationPoint: Equatable, Sendable {
    var x: Double
    var y: Double
    var include: Bool
}

/// One mask the segmenter proposes for a set of clicks: raw logits on the model's low-resolution grid
/// (positive inside the object) and the model's own score. Rasterize with `SegmentationPostprocessing`.
struct SegmentationCandidate: Equatable, Sendable {
    var score: Float
    var width: Int
    var height: Int
    var logits: [Float]

    /// Pixels the model considers inside the object.
    var insideCount: Int { logits.reduce(0) { $0 + ($1 > 0 ? 1 : 0) } }
}

enum SegmentationError: LocalizedError, Equatable {
    case missingModel, invalidModel, noPhoto, notPrepared, noPoints, invalidOutput

    var errorDescription: String? {
        switch self {
        case .missingModel: "The selection model is missing. Reinstall the complete app bundle."
        case .invalidModel: "The selection model is incompatible with this app."
        case .noPhoto: "The photo could not be decoded for selection."
        case .notPrepared: "The photo has not been analyzed for selection yet."
        case .noPoints: "Click the photo to choose what to select."
        case .invalidOutput: "The selection model returned an unreadable result."
        }
    }
}

/// Promptable segmentation: look at a photo once, then answer many click sets quickly.
/// The Core ML implementation is `SAM2Segmenter`; tests use a deterministic fake.
protocol PromptableSegmenter: Sendable {
    /// Analyzes the photo (about a second on the target Mac) and keeps the result for `candidates`.
    func prepare(photoID: UUID, image: CGImage) async throws
    /// Candidate masks for the clicks, ordered from the smallest region to the largest
    /// (part, object, whole), not by score.
    func candidates(photoID: UUID, points: [SegmentationPoint]) async throws -> [SegmentationCandidate]
    /// Drops everything held in memory (models and analyzed photos).
    func unload() async
}

/// Pure steps around the model: coordinate mapping and turning logits into a mask.
enum SegmentationPostprocessing {
    /// The model's input is the photo stretched to a square (no letterbox).
    static let inputSide = 1024
    /// The prompt encoder accepts at most this many clicks.
    static let maximumPoints = 16

    /// Click positions in the model's 1024 × 1024 input space, as (x, y, label) with label 1 = include.
    static func modelPoints(_ points: [SegmentationPoint]) -> [(x: Float, y: Float, label: Int32)] {
        // Keep the most recent clicks when there are too many: they carry the photographer's latest intent.
        points.suffix(maximumPoints).map { point in
            (Float(min(max(point.x, 0), 1) * Double(inputSide)),
             Float(min(max(point.y, 0), 1) * Double(inputSide)),
             point.include ? 1 : 0)
        }
    }

    /// Orders candidates from the smallest region to the largest.
    static func orderedByArea(_ candidates: [SegmentationCandidate]) -> [SegmentationCandidate] {
        candidates.map { ($0, $0.insideCount) }.sorted { $0.1 < $1.1 }.map(\.0)
    }

    /// The candidate's mask at the requested size: logits are upsampled bilinearly first and thresholded
    /// after, so the edge follows the model's soft boundary instead of a blocky 256-px grid.
    /// Returns row-major 8-bit values, 255 inside.
    static func maskPixels(_ candidate: SegmentationCandidate, width: Int, height: Int) -> [UInt8] {
        guard width > 0, height > 0, candidate.width > 0, candidate.height > 0,
              candidate.logits.count == candidate.width * candidate.height else { return [] }
        let sourceWidth = candidate.width, sourceHeight = candidate.height
        // Column sample positions are the same for every row, so they are computed once.
        var columnIndex0 = [Int](repeating: 0, count: width), columnIndex1 = columnIndex0
        var columnFraction = [Float](repeating: 0, count: width)
        for x in 0 ..< width {
            let sx = min(max((Double(x) + 0.5) * Double(sourceWidth) / Double(width) - 0.5, 0), Double(sourceWidth - 1))
            columnIndex0[x] = Int(sx)
            columnIndex1[x] = min(Int(sx) + 1, sourceWidth - 1)
            columnFraction[x] = Float(sx - Double(Int(sx)))
        }
        var pixels = [UInt8](repeating: 0, count: width * height)
        candidate.logits.withUnsafeBufferPointer { logits in
            pixels.withUnsafeMutableBufferPointer { output in
                for y in 0 ..< height {
                    let sy = min(max((Double(y) + 0.5) * Double(sourceHeight) / Double(height) - 0.5, 0), Double(sourceHeight - 1))
                    let y0 = Int(sy), y1 = min(y0 + 1, sourceHeight - 1), fy = Float(sy - Double(y0))
                    let top = y0 * sourceWidth, bottom = y1 * sourceWidth
                    for x in 0 ..< width {
                        let (x0, x1, fx) = (columnIndex0[x], columnIndex1[x], columnFraction[x])
                        let upper = logits[top + x0] * (1 - fx) + logits[top + x1] * fx
                        let lower = logits[bottom + x0] * (1 - fx) + logits[bottom + x1] * fx
                        if upper * (1 - fy) + lower * fy > 0 { output[y * width + x] = 255 }
                    }
                }
            }
        }
        return pixels
    }
}

/// A small least-recently-used store, so only the photo being edited and a neighbor stay analyzed.
struct RecentlyUsedCache<Key: Hashable, Value> {
    let capacity: Int
    private var order: [Key] = []
    private var values: [Key: Value] = [:]

    init(capacity: Int) { self.capacity = max(1, capacity) }

    var keys: [Key] { order }

    mutating func value(for key: Key) -> Value? {
        guard let value = values[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return value
    }

    mutating func insert(_ value: Value, for key: Key) {
        values[key] = value
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > capacity {
            values[order.removeFirst()] = nil
        }
    }

    mutating func removeAll() {
        order = []
        values = [:]
    }
}

extension SegmentationPostprocessing {
    /// An 8-bit grayscale PNG of row-major mask pixels, the format `SubjectMask` stores.
    static func png(pixels: [UInt8], width: Int, height: Int) -> Data? {
        guard width > 0, height > 0, pixels.count == width * height,
              let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
