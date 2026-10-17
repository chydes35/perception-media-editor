@preconcurrency import AVFoundation
import Foundation
import Metal
import Testing
@testable import PerceptionEditor

/// Gate G4: the generated OCIO shaders on real V-Log frames against PyOpenColorIO's CPU processor on
/// the same pixels. Run with
///   PME_VLOG_SHORT=/Volumes/ExSSD1/Pictures/110_PANA/P1107158.MOV
///   PME_VIDEO_OUTPUT_DIR=<a disposable folder>
///   PME_OCIO_PYTHON=<venv python with scripts/ocio/requirements.txt installed>
/// The test writes the decoded pixels to `g4-input.json` there, runs
/// `generate-shaders.py --reference-frames`, and compares.
struct RealVideoOCIOTests {
    static let environment = ProcessInfo.processInfo.environment
    static let enabled = ["PME_VLOG_SHORT", "PME_VIDEO_OUTPUT_DIR", "PME_OCIO_PYTHON"].allSatisfy { environment[$0] != nil }
        && MTLCreateSystemDefaultDevice() != nil

    @Test(.enabled(if: enabled))
    func ocioShadersMatchPyOpenColorIOOnRealVLogFrames() async throws {
        let source = URL(fileURLWithPath: Self.environment["PME_VLOG_SHORT"]!)
        let folder = URL(fileURLWithPath: Self.environment["PME_VIDEO_OUTPUT_DIR"]!)
        #expect(!folder.path.contains("/Pictures/"), "Gate output must not go next to the originals")
        let before = try FileManager.default.attributesOfItem(atPath: source.path)

        let kernels = try #require(OCIOColorKernels.shared, "\(String(describing: OCIOColorKernels.loadError))")
        let decoder = try VideoColorKernels()
        var inputs: [[Float]] = [], linear: [[Float]] = [], display: [[Float]] = []
        for buffer in try await Self.frames(source, indices: [0, 36, 71]) {
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
            let decoded = try decoder.makeWorkingTexture(width: width, height: height)
            let toLinear = try decoder.makeWorkingTexture(width: width, height: height)
            let toDisplay = try decoder.makeWorkingTexture(width: width, height: height)
            let commandBuffer = try #require(kernels.runtime.queue.makeCommandBuffer())
            try decoder.decode(buffer, matrix: .rec709, into: decoded, commandBuffer: commandBuffer)
            try kernels.toSceneLinear(decoded, from: .vLogVGamut, into: toLinear, commandBuffer: commandBuffer)
            try kernels.toDisplay(decoded, from: .vLogVGamut, into: toDisplay, commandBuffer: commandBuffer)
            commandBuffer.commit()
            await commandBuffer.completed()
            // A 64 × 36 grid of positions per frame: 2 304 pixels, 6 912 over three frames.
            for row in 0 ..< 36 {
                for column in 0 ..< 64 {
                    let x = (column * 2 + 1) * width / 128, y = (row * 2 + 1) * height / 72
                    inputs.append(Self.pixel(decoded, x, y))
                    linear.append(Self.pixel(toLinear, x, y))
                    display.append(Self.pixel(toDisplay, x, y))
                }
            }
        }

        let inputURL = folder.appendingPathComponent("g4-input.json"), referenceURL = folder.appendingPathComponent("g4-reference.json")
        try JSONEncoder().encode(["inputs": inputs]).write(to: inputURL)
        let script = OCIOGeneratedSourceTests.repositoryRoot.appending(path: "scripts/ocio/generate-shaders.py")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.environment["PME_OCIO_PYTHON"]!)
        process.arguments = ["-I", script.path, "--reference-frames", inputURL.path, referenceURL.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let reference = try JSONDecoder().decode([String: [[Float]]].self, from: Data(contentsOf: referenceURL))

        let (linearWorst, displayWorst) = (Self.worst(linear, reference["linear"] ?? []), Self.worst(display, reference["display"] ?? []))
        print("G4 on \(inputs.count) real V-Log pixels: linear worst \(linearWorst) of its limit, display worst \(displayWorst) of its limit")
        #expect(linearWorst <= 1, "Linear Rec. 709 departs from OCIO by \(linearWorst) of the 1e-3 / 0.2% limit")
        #expect(displayWorst <= 1, "The ACES view departs from OCIO by \(displayWorst) of the 1e-3 limit")

        let after = try FileManager.default.attributesOfItem(atPath: source.path)
        #expect(before[.size] as? Int == after[.size] as? Int && before[.modificationDate] as? Date == after[.modificationDate] as? Date,
                "The original must be untouched")
    }

    /// Each error as a fraction of G4's limit: 1e-3 absolute up to 1, 0.2% relative above.
    static func worst(_ actual: [[Float]], _ expected: [[Float]]) -> Double {
        guard actual.count == expected.count else { return .infinity }
        var worst = 0.0
        for (a, e) in zip(actual, expected) {
            for channel in 0 ..< 3 {
                let limit = abs(e[channel]) > 1 ? 2e-3 : 1e-3
                worst = max(worst, OCIOGolden.error(Double(e[channel]), Double(a[channel])) / limit)
            }
        }
        return worst
    }

    static func pixel(_ texture: MTLTexture, _ x: Int, _ y: Int) -> [Float] {
        var half = [Float16](repeating: 0, count: 4)
        texture.getBytes(&half, bytesPerRow: 8, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        return half.prefix(3).map(Float.init)
    }

    /// The file's own frames at `indices`, as the full-range `xf22` the compositor receives.
    static func frames(_ url: URL, indices: Set<Int>) async throws -> [CVPixelBuffer] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_422YpCbCr10BiPlanarFullRange
        ])
        reader.add(output)
        #expect(reader.startReading())
        var frames: [CVPixelBuffer] = [], index = 0
        while frames.count < indices.count, let sample = output.copyNextSampleBuffer() {
            if indices.contains(index), let buffer = CMSampleBufferGetImageBuffer(sample) { frames.append(buffer) }
            index += 1
        }
        reader.cancelReading()
        #expect(frames.count == indices.count)
        return frames
    }
}
