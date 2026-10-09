import CoreImage
import CoreVideo
import Foundation
@preconcurrency import Vision

/// Independent foreground evidence is used only for instances predominantly classified as people.
/// This avoids subtracting a foreground tree or other object from genuine sky gaps.
enum SkyForegroundExclusion {
    static func refine(sky: [Float], source: CIImage, semanticPeople: CIImage,
                       width: Int, height: Int, context: CIContext) throws -> [Float] {
        try Task.checkCancellation()
        let handler = VNImageRequestHandler(ciImage: source, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        let foreground: CIImage
        do {
            try handler.perform([request])
            try Task.checkCancellation()
            guard let result = request.results?.first, !result.allInstances.isEmpty else { return sky }
            let labelsImage = CIImage(cvPixelBuffer: result.instanceMask, options: [.colorSpace: NSNull()])
            let labelWidth = Int(labelsImage.extent.width), labelHeight = Int(labelsImage.extent.height)
            var labels = [UInt8](repeating: 0, count: labelWidth * labelHeight)
            var people = labels
            context.render(labelsImage, toBitmap: &labels, rowBytes: labelWidth, bounds: labelsImage.extent, format: .L8, colorSpace: nil)
            let scaledPeople = semanticPeople.transformed(by: CGAffineTransform(
                scaleX: CGFloat(labelWidth) / semanticPeople.extent.width,
                y: CGFloat(labelHeight) / semanticPeople.extent.height))
            context.render(scaledPeople, toBitmap: &people, rowBytes: labelWidth, bounds: labelsImage.extent, format: .L8, colorSpace: nil)
            let instances = try personInstances(labels: labels, semanticPeople: people).intersection(result.allInstances)
            guard !instances.isEmpty else { return sky }
            foreground = CIImage(cvPixelBuffer: try result.generateScaledMaskForImage(forInstances: instances, from: handler),
                                 options: [.colorSpace: NSNull()])
        } catch {
            // An auxiliary native-model failure must not discard otherwise usable sky.
            try Task.checkCancellation()
            return sky
        }
        try Task.checkCancellation()
        let scaled = foreground.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / foreground.extent.width,
                                                                  y: CGFloat(height) / foreground.extent.height))
        var confidence = [UInt8](repeating: 0, count: width * height)
        context.render(scaled, toBitmap: &confidence, rowBytes: width,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .L8, colorSpace: nil)
        return try exclude(sky: sky, foreground: confidence)
    }

    static func personInstances(labels: [UInt8], semanticPeople: [UInt8]) throws -> IndexSet {
        guard labels.count == semanticPeople.count else { return [] }
        var totals = [Int](repeating: 0, count: 256)
        var overlaps = totals
        for i in labels.indices {
            if i % 4096 == 0 { try Task.checkCancellation() }
            let id = Int(labels[i])
            guard id != 0 else { continue }
            totals[id] += 1
            if semanticPeople[i] >= 128 { overlaps[id] += 1 }
        }
        return IndexSet((1..<256).filter { totals[$0] >= 16 && Double(overlaps[$0]) / Double(totals[$0]) >= 0.6 })
    }

    /// Leave uncertain boundaries unchanged, then smoothly remove high-confidence interiors.
    static func exclude(sky: [Float], foreground: [UInt8]) throws -> [Float] {
        guard sky.count == foreground.count else { return sky }
        var result = sky
        for i in result.indices {
            if i % 4096 == 0 { try Task.checkCancellation() }
            let confidence = max(0, Float(foreground[i]) - 230) / 25
            result[i] *= 1 - confidence
        }
        return result
    }
}
