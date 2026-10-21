import CoreGraphics
import CoreML
import CoreVideo
import Foundation

/// SAM 2.1 Small on Core ML (see plans/active/click-to-select-masks.md). The image encoder runs once per
/// photo; each click set then costs a prompt encoder and mask decoder pass (about 30 ms).
/// Compute units are CPU and GPU only: the Neural Engine takes minutes to load the encoder and the decoder
/// does not run there.
actor SAM2Segmenter: PromptableSegmenter {
    private struct Embeddings {
        let featuresS0: MLFeatureValue
        let featuresS1: MLFeatureValue
        let imageEmbedding: MLFeatureValue
    }
    private struct Models {
        let encoder: MLModel
        let prompt: MLModel
        let decoder: MLModel
    }

    private let directory: URL?
    private var models: Models?
    private var embeddings = RecentlyUsedCache<UUID, Embeddings>(capacity: 2)

    /// `directory` holds the three compiled models; nil uses the app bundle's `Models` folder.
    init(directory: URL? = nil) { self.directory = directory }

    func prepare(photoID: UUID, image: CGImage) async throws {
        try Task.checkCancellation()
        if embeddings.value(for: photoID) != nil { return }
        let models = try loadedModels()
        let buffer = try Self.pixelBuffer(from: image)
        let output = try Self.run(models.encoder, MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)]))
        guard let s0 = output.featureValue(for: "feats_s0"), let s1 = output.featureValue(for: "feats_s1"),
              let embedding = output.featureValue(for: "image_embedding") else { throw SegmentationError.invalidModel }
        embeddings.insert(Embeddings(featuresS0: s0, featuresS1: s1, imageEmbedding: embedding), for: photoID)
    }

    func candidates(photoID: UUID, points: [SegmentationPoint]) async throws -> [SegmentationCandidate] {
        try Task.checkCancellation()
        guard !points.isEmpty else { throw SegmentationError.noPoints }
        guard let embeddings = embeddings.value(for: photoID) else { throw SegmentationError.notPrepared }
        let models = try loadedModels()
        let clicks = SegmentationPostprocessing.modelPoints(points)

        let pointArray = try MLMultiArray(shape: [1, NSNumber(value: clicks.count), 2], dataType: .float32)
        let labelArray = try MLMultiArray(shape: [1, NSNumber(value: clicks.count)], dataType: .int32)
        for (index, click) in clicks.enumerated() {
            pointArray[[0, index as NSNumber, 0]] = NSNumber(value: click.x)
            pointArray[[0, index as NSNumber, 1]] = NSNumber(value: click.y)
            labelArray[[0, index as NSNumber]] = NSNumber(value: click.label)
        }
        let prompt = try Self.run(models.prompt, MLDictionaryFeatureProvider(dictionary: [
            "points": MLFeatureValue(multiArray: pointArray),
            "labels": MLFeatureValue(multiArray: labelArray),
        ]))
        guard let sparse = prompt.featureValue(for: "sparse_embeddings"),
              let dense = prompt.featureValue(for: "dense_embeddings") else { throw SegmentationError.invalidModel }

        try Task.checkCancellation()
        let decoded = try Self.run(models.decoder, MLDictionaryFeatureProvider(dictionary: [
            "sparse_embedding": sparse,
            "dense_embedding": dense,
            "feats_s0": embeddings.featuresS0,
            "feats_s1": embeddings.featuresS1,
            "image_embedding": embeddings.imageEmbedding,
        ]))
        guard let scores = decoded.featureValue(for: "scores")?.multiArrayValue,
              let masks = decoded.featureValue(for: "low_res_masks")?.multiArrayValue else { throw SegmentationError.invalidModel }
        return SegmentationPostprocessing.orderedByArea(try Self.candidates(scores: scores, masks: masks))
    }

    func unload() async {
        models = nil
        embeddings.removeAll()
    }

    /// The synchronous prediction: this actor does one model pass at a time and checks for cancellation between passes.
    private static func run(_ model: MLModel, _ input: MLFeatureProvider) throws -> MLFeatureProvider {
        try model.prediction(from: input)
    }

    // MARK: - Loading

    private func loadedModels() throws -> Models {
        if let models { return models }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        func load(_ name: String) throws -> MLModel {
            let url = directory?.appendingPathComponent("\(name).mlmodelc")
                ?? Bundle.main.url(forResource: name, withExtension: "mlmodelc", subdirectory: "Models")
            guard let url, FileManager.default.fileExists(atPath: url.path) else { throw SegmentationError.missingModel }
            return try MLModel(contentsOf: url, configuration: configuration)
        }
        let loaded = Models(encoder: try load("SAM2ImageEncoder"), prompt: try load("SAM2PromptEncoder"),
                            decoder: try load("SAM2MaskDecoder"))
        models = loaded
        return loaded
    }

    // MARK: - Conversions

    /// The photo stretched to the model's square input as a BGRA pixel buffer.
    static func pixelBuffer(from image: CGImage) throws -> CVPixelBuffer {
        let side = SegmentationPostprocessing.inputSide
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(nil, side, side, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess,
              let buffer else { throw SegmentationError.noPhoto }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { throw SegmentationError.noPhoto }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return buffer
    }

    /// Reads `scores` [1,K] and `low_res_masks` [1,K,H,W] whatever their element type or strides.
    static func candidates(scores: MLMultiArray, masks: MLMultiArray) throws -> [SegmentationCandidate] {
        let shape = masks.shape.map(\.intValue)
        guard shape.count == 4, shape[0] == 1, shape[1] > 0, shape[2] > 0, shape[3] > 0,
              scores.count >= shape[1] else { throw SegmentationError.invalidOutput }
        let strides = masks.strides.map(\.intValue)
        let (count, height, width) = (shape[1], shape[2], shape[3])
        return (0 ..< count).map { index in
            var logits = [Float](repeating: 0, count: width * height)
            for y in 0 ..< height {
                for x in 0 ..< width {
                    logits[y * width + x] = value(masks, at: index * strides[1] + y * strides[2] + x * strides[3])
                }
            }
            return SegmentationCandidate(score: value(scores, at: index * scores.strides[scores.strides.count - 1].intValue),
                                         width: width, height: height, logits: logits)
        }
    }

    private static func value(_ array: MLMultiArray, at offset: Int) -> Float {
        switch array.dataType {
        case .float32: return array.dataPointer.assumingMemoryBound(to: Float.self)[offset]
        case .double: return Float(array.dataPointer.assumingMemoryBound(to: Double.self)[offset])
        #if arch(arm64)
        case .float16: return Float(array.dataPointer.assumingMemoryBound(to: Float16.self)[offset])
        #endif
        default: return array[offset].floatValue
        }
    }
}
