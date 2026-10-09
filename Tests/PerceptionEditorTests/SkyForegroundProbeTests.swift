import CoreImage
import CoreVideo
import Foundation
import Testing
@preconcurrency import Vision
@testable import PerceptionEditor

struct SkyForegroundProbeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PME_SKY_FOREGROUND_INPUT"] != nil))
    func inspectIndependentForegroundEvidence() throws {
        let env = ProcessInfo.processInfo.environment
        let path = try #require(env["PME_SKY_FOREGROUND_INPUT"])
        let source = try #require(PhotoSourceLoader.load(URL(fileURLWithPath: path), maxDimension: SkyAnalyzer.maximumMaskDimension))
        let folder = URL(fileURLWithPath: try #require(env["PME_SKY_FOREGROUND_OUTPUT"]))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let context = CIContext(options: [.cacheIntermediates: false, .memoryTarget: 128])
        defer { context.clearCaches() }
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let start = Date()
        try VNImageRequestHandler(ciImage: source, options: [:]).perform([request])
        let buffer = try #require(request.results?.first?.pixelBuffer)
        let mask = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
        try context.writePNGRepresentation(of: mask, to: folder.appendingPathComponent("person.png"), format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        print("SKY_FOREGROUND accurate person seconds", Date().timeIntervalSince(start), "extent", mask.extent)
        let people = VNGeneratePersonInstanceMaskRequest()
        let peopleHandler = VNImageRequestHandler(ciImage: source, options: [:])
        try peopleHandler.perform([people])
        if let result = people.results?.first, !result.allInstances.isEmpty {
            let image = CIImage(cvPixelBuffer: try result.generateScaledMaskForImage(forInstances: result.allInstances, from: peopleHandler), options: [.colorSpace: NSNull()])
            try context.writePNGRepresentation(of: image, to: folder.appendingPathComponent("people.png"), format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        }
        let foreground = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(ciImage: source, options: [:])
        try handler.perform([foreground])
        if let result = foreground.results?.first, !result.allInstances.isEmpty {
            let image = CIImage(cvPixelBuffer: try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler), options: [.colorSpace: NSNull()])
            try context.writePNGRepresentation(of: image, to: folder.appendingPathComponent("foreground.png"), format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        }
    }
}
