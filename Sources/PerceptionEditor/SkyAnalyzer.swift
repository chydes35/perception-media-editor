import CoreImage
import CoreML
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum SkySelectionError: LocalizedError, Equatable {
    case missingModel, invalidModel, noPhoto, noSky, invalidMask

    var errorDescription: String? {
        switch self {
        case .missingModel: "The sky detection model is missing. Reinstall the complete app bundle."
        case .invalidModel: "The sky detection model is incompatible with this app."
        case .noPhoto: "The photo could not be decoded for sky selection."
        case .noSky: "No sky was found in this photo. You can use a gradient or brush mask instead."
        case .invalidMask: "The sky mask could not be prepared."
        }
    }
}

/// Local Core ML inference on a separate actor. The model is loaded lazily and reused;
/// photographs are never sent to a server, and inference does not occupy PhotoRenderer.
actor SkyAnalysisService {
    private var model: MLModel?

    func analyze(url: URL) throws -> Data {
        if model == nil {
            guard let resource = Bundle.main.url(forResource: "SkySegmentation", withExtension: "mlmodelc", subdirectory: "Models")
            else { throw SkySelectionError.missingModel }
            model = try SkyAnalyzer.loadModel(at: resource)
        }
        guard let model else { throw SkySelectionError.missingModel }
        return try SkyAnalyzer.analyze(url: url, model: model)
    }
}

enum SkyAnalyzer {
    /// Mask/guide work is bounded independently of the original RAW image's dimensions.
    static let maximumMaskDimension = 1536.0

    static func loadModel(at url: URL) throws -> MLModel {
        let configuration = MLModelConfiguration()
        // GPU loading avoids the long first-use Neural Engine specialization on base M1.
        configuration.computeUnits = .cpuAndGPU
        return try MLModel(contentsOf: url, configuration: configuration)
    }

    static func analyze(url: URL, model: MLModel) throws -> Data {
        try Task.checkCancellation()
        guard let source = PhotoSourceLoader.load(url, maxDimension: maximumMaskDimension) else {
            throw SkySelectionError.noPhoto
        }
        guard let input = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint,
              let fields = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String],
              let params = fields["com.apple.coreml.model.preview.params"]?.data(using: .utf8),
              let classes = try? JSONDecoder().decode(ClassList.self, from: params),
              let skyID = classes.labels.firstIndex(of: "sky (other)") else { throw SkySelectionError.invalidModel }

        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, input.pixelsWide, input.pixelsHigh,
                                        input.pixelFormatType, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw SkySelectionError.invalidMask }
        let context = CIContext(options: [.cacheIntermediates: false, .memoryTarget: 128])
        defer { context.clearCaches() }
        // Resize the whole oriented photo; center-cropping would discard wide landscapes.
        let resized = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(input.pixelsWide) / source.extent.width,
                                               y: CGFloat(input.pixelsHigh) / source.extent.height))
        context.render(resized, to: buffer, bounds: CGRect(x: 0, y: 0, width: input.pixelsWide, height: input.pixelsHigh),
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let features = try MLDictionaryFeatureProvider(dictionary: ["image": buffer])
        try Task.checkCancellation()
        let prediction = try model.prediction(from: features)
        try Task.checkCancellation()
        guard let labels = prediction.featureValue(for: "semanticPredictions")?.multiArrayValue else {
            throw SkySelectionError.invalidModel
        }
        let coarse = try labelMask(labels, skyID: skyID)
        let width = max(1, Int(source.extent.width.rounded()))
        let height = max(1, Int(source.extent.height.rounded()))
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let upscaled = coarse.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / coarse.extent.width,
                                                               y: CGFloat(height) / coarse.extent.height))
        let guideImage = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
                "inputGVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
                "inputBVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
            ])
        var guideBytes = [UInt8](repeating: 0, count: width * height)
        var maskBytes = guideBytes
        context.render(guideImage, toBitmap: &guideBytes, rowBytes: width, bounds: extent,
                       format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        let rawContext = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false, .memoryTarget: 128])
        defer { rawContext.clearCaches() }
        rawContext.render(upscaled, toBitmap: &maskBytes, rowBytes: width, bounds: extent, format: .L8, colorSpace: nil)
        var refined = SkyEdgeRefiner.refine(
            mask: maskBytes.map { Float($0) / 255 }, guide: guideBytes.map { Float($0) / 255 },
            width: width, height: height, radius: max(2, Int(Double(max(width, height)) / 448 * 2)), epsilon: 0.001
        )
        if let treeID = classes.labels.firstIndex(of: "tree"),
           let trees = try? labelMask(labels, skyID: treeID) {
            let scaledTrees = trees.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / trees.extent.width,
                                                                      y: CGFloat(height) / trees.extent.height))
            var treeBytes = [UInt8](repeating: 0, count: width * height)
            rawContext.render(scaledTrees, toBitmap: &treeBytes, rowBytes: width, bounds: extent, format: .L8, colorSpace: nil)
            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            context.render(source, toBitmap: &rgba, rowBytes: width * 4, bounds: extent, format: .RGBA8,
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            let recovered = try SkyBranchRecovery.recover(mask: maskBytes, rgba: rgba, trees: treeBytes,
                                                         width: width, height: height)
            if recovered != maskBytes {
                let added = SkyEdgeRefiner.refine(
                    mask: recovered.map { Float($0) / 255 }, guide: guideBytes.map { Float($0) / 255 },
                    width: width, height: height, radius: max(2, Int(Double(max(width, height)) / 448 * 2)), epsilon: 0.001
                )
                // Recovery cannot erase pixels from the previously offered guided mask.
                for i in refined.indices { refined[i] = max(refined[i], added[i]) }
            }
        }
        if let personID = classes.labels.firstIndex(of: "person"),
           let people = try? labelMask(labels, skyID: personID) {
            refined = try autoreleasepool {
                try SkyForegroundExclusion.refine(sky: refined, source: source, semanticPeople: people,
                                                  width: width, height: height, context: rawContext)
            }
        }
        try Task.checkCancellation()
        let bytes = Data(refined.map { UInt8((min(1, max(0, $0)) * 255).rounded()) })
        let mask = CIImage(bitmapData: bytes, bytesPerRow: width, size: extent.size, format: .L8, colorSpace: nil)
        return try encode(mask, context: rawContext)
    }

    private struct ClassList: Decodable { let labels: [String] }

    /// Preserve the model's top-first rows in Core Image's bitmap image representation.
    static func labelMask(_ labels: MLMultiArray, skyID: Int) throws -> CIImage {
        let shape = labels.shape.map(\.intValue)
        guard labels.dataType == .int32, shape.count == 2 || (shape.count == 3 && shape[0] == 1),
              let width = shape.last, width > 0 else { throw SkySelectionError.invalidModel }
        let height = shape[shape.count - 2]
        guard height > 0 else { throw SkySelectionError.invalidModel }
        let strides = labels.strides.map(\.intValue)
        let rowStride = strides[strides.count - 2], columnStride = strides[strides.count - 1]
        let values = labels.dataPointer.assumingMemoryBound(to: Int32.self)
        var pixels = [UInt8](repeating: 0, count: width * height)
        var skyCount = 0
        for y in 0 ..< height {
            for x in 0 ..< width where values[y * rowStride + x * columnStride] == Int32(skyID) {
                pixels[y * width + x] = 255
                skyCount += 1
            }
        }
        guard skyCount >= max(8, width * height / 1000) else { throw SkySelectionError.noSky }
        return CIImage(bitmapData: Data(pixels), bytesPerRow: width, size: CGSize(width: width, height: height), format: .L8, colorSpace: nil)
    }

    private static func encode(_ image: CIImage, context: CIContext) throws -> Data {
        guard let raster = context.createCGImage(image, from: image.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        else { throw SkySelectionError.invalidMask }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { throw SkySelectionError.invalidMask }
        CGImageDestinationAddImage(destination, raster, nil)
        guard CGImageDestinationFinalize(destination) else { throw SkySelectionError.invalidMask }
        return output as Data
    }
}
