import CoreImage
import CoreVideo
import Foundation
import Testing
@preconcurrency import Vision
@testable import PerceptionEditor

struct GroupSelectionProbeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PME_GROUP_PROBE_INPUT"] != nil))
    func inspectWholePersonSegmentation() throws {
        let env = ProcessInfo.processInfo.environment
        let url = URL(fileURLWithPath: try #require(env["PME_GROUP_PROBE_INPUT"]))
        let output = URL(fileURLWithPath: try #require(env["PME_GROUP_PROBE_OUTPUT"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let image = try #require(PhotoSourceLoader.load(url, maxDimension: 3072))
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        let humans = VNDetectHumanRectanglesRequest()
        humans.upperBodyOnly = true
        try handler.perform([humans])
        print("GROUP_PROBE human rectangles", humans.results?.map { "\($0.confidence):\($0.boundingBox)" } ?? [])
        for (index, human) in (humans.results ?? []).prefix(3).enumerated() {
            let box = human.boundingBox
            let rect = CGRect(x: (box.minX - box.width * 0.5) * image.extent.width,
                              y: (box.minY - box.height * 2.5) * image.extent.height,
                              width: box.width * 2 * image.extent.width,
                              height: box.height * 4 * image.extent.height).intersection(image.extent)
            let crop = image.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = .accurate
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            let start = Date()
            try VNImageRequestHandler(ciImage: crop, options: [:]).perform([request])
            let buffer = try #require(request.results?.first?.pixelBuffer)
            let mask = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
            let context = CIContext(options: [.cacheIntermediates: false])
            try context.writePNGRepresentation(of: crop, to: output.appendingPathComponent("crop-\(index)-source.png"), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            try context.writePNGRepresentation(of: mask, to: output.appendingPathComponent("crop-\(index)-mask.png"), format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
            print("GROUP_PROBE crop",index,"seconds",Date().timeIntervalSince(start),"rect",rect)
        }
        for (name, quality) in [("balanced", VNGeneratePersonSegmentationRequest.QualityLevel.balanced), ("accurate", .accurate)] {
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = quality
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            let start = Date()
            try handler.perform([request])
            let buffer = try #require(request.results?.first?.pixelBuffer)
            let mask = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
            let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])
            try context.writePNGRepresentation(of: mask, to: output.appendingPathComponent("\(name).png"), format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
            print("GROUP_PROBE",name,"seconds",Date().timeIntervalSince(start),"size",mask.extent)
        }
    }
}
