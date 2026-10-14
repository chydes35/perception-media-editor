import CoreImage
import CoreML
import CoreVideo
import Foundation
import Testing
@testable import PerceptionEditor

struct SkyBranchProbeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PME_SKY_BRANCH_INPUT"] != nil))
    func inspectSemanticClasses() throws {
        let env = ProcessInfo.processInfo.environment
        let path = try #require(env["PME_SKY_BRANCH_INPUT"])
        let source = try #require(PhotoSourceLoader.load(URL(fileURLWithPath: path), maxDimension: 1536))
        let model = try SkyAnalyzer.loadModel(at: URL(fileURLWithPath: try #require(env["PERCEPTION_SKY_MODEL_PATH"])))
        let fields = try #require(model.modelDescription.metadata[.creatorDefinedKey] as? [String: String])
        let metadata = try #require(fields["com.apple.coreml.model.preview.params"]?.data(using: .utf8))
        let classes = try #require((JSONSerialization.jsonObject(with: metadata) as? [String: Any])?["labels"] as? [String])
        let input = try #require(model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint)
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, input.pixelsWide, input.pixelsHigh, input.pixelFormatType,
                                  [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess)
        let pixels = try #require(buffer)
        let context = CIContext(options: [.cacheIntermediates: false])
        defer { context.clearCaches() }
        context.render(source.transformed(by: CGAffineTransform(scaleX: CGFloat(input.pixelsWide) / source.extent.width,
                                                                y: CGFloat(input.pixelsHigh) / source.extent.height)),
                       to: pixels, bounds: CGRect(x: 0, y: 0, width: input.pixelsWide, height: input.pixelsHigh),
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let prediction = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": pixels]))
        print("SKY_BRANCH outputs", model.modelDescription.outputDescriptionsByName)
        let labels = try #require(prediction.featureValue(for: "semanticPredictions")?.multiArrayValue)
        let width = labels.shape.last!.intValue, height = labels.shape[labels.shape.count - 2].intValue
        let strides = labels.strides.map(\.intValue)
        let values = labels.dataPointer.assumingMemoryBound(to: Int32.self)
        var counts: [Int: Int] = [:]
        for y in 0 ..< height {
            for x in 0 ..< width { counts[Int(values[y * strides[strides.count - 2] + x * strides.last!]), default: 0] += 1 }
        }
        print("SKY_BRANCH classes", counts.sorted { $0.value > $1.value }.map { "\(classes[$0.key]):\($0.value)" })
        for (x, y) in [(0.62, 0.04), (0.44, 0.12), (0.48, 0.16), (0.52, 0.10), (0.32, 0.035), (0.95, 0.2), (0.05, 0.7)] {
            let id = Int(values[Int(y * Double(height)) * strides[strides.count - 2] + Int(x * Double(width)) * strides.last!])
            print("SKY_BRANCH point", x, y, classes[id])
        }
        if let path = env["PME_SKY_BRANCH_OUTPUT"] {
            let output = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let width = Int(source.extent.width), height = Int(source.extent.height)
            let skyID = try #require(classes.firstIndex(of: "sky (other)"))
            let treeID = try #require(classes.firstIndex(of: "tree"))
            let sky = try SkyAnalyzer.labelMask(labels, skyID: skyID)
            let tree = try SkyAnalyzer.labelMask(labels, skyID: treeID)
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            let rawContext = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])
            defer { rawContext.clearCaches() }
            var mask = [UInt8](repeating: 0, count: width * height)
            var trees = mask
            var rgb = [UInt8](repeating: 0, count: width * height * 4)
            func scaled(_ image: CIImage) -> CIImage {
                image.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / image.extent.width,
                                                       y: CGFloat(height) / image.extent.height))
            }
            rawContext.render(scaled(sky), toBitmap: &mask, rowBytes: width, bounds: bounds, format: .L8, colorSpace: nil)
            rawContext.render(scaled(tree), toBitmap: &trees, rowBytes: width, bounds: bounds, format: .L8, colorSpace: nil)
            context.render(source, toBitmap: &rgb, rowBytes: width * 4, bounds: bounds, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            let recovered = try SkyBranchRecovery.recover(mask: mask, rgba: rgb, trees: trees, width: width, height: height)
            let recoveredImage = CIImage(bitmapData: Data(recovered), bytesPerRow: width, size: bounds.size, format: .L8, colorSpace: nil)
            try SubjectAnalyzer.encodeMask(recoveredImage).write(to: output.appendingPathComponent("recovered.png"))
            print("SKY_BRANCH recovered pixels", zip(mask, recovered).filter { $0.1 > $0.0 }.count)
            let labelWidth = labels.shape.last!.intValue, labelHeight = labels.shape[labels.shape.count - 2].intValue
            var palette = [UInt8](repeating: 0, count: labelWidth * labelHeight * 4)
            for y in 0 ..< labelHeight {
                for x in 0 ..< labelWidth {
                    let id = Int(values[y * strides[strides.count - 2] + x * strides.last!])
                    let i = (y * labelWidth + x) * 4
                    let label = classes[id]
                    if label == "sky (other)" { palette[i + 2] = 255 }
                    else if label.contains("tree") { palette[i + 1] = 255 }
                    else { palette[i] = 255 }
                    palette[i + 3] = 255
                }
            }
            let image = CIImage(bitmapData: Data(palette), bytesPerRow: labelWidth * 4,
                                size: CGSize(width: labelWidth, height: labelHeight), format: .RGBA8, colorSpace: nil)
            try context.writePNGRepresentation(of: image, to: output.appendingPathComponent("classes.png"),
                                               format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
    }
}
