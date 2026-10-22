@preconcurrency import AVFoundation
import CoreVideo
import Foundation
import Metal
import Testing
@testable import PerceptionEditor

/// Pixel-format facts need no GPU.
struct YCbCrBufferLayoutTests {
    @Test func everyBiPlanarFormatMapsToItsDepthRangeAndSubsampling() {
        let expected: [(OSType, Int, Bool, Int, Int)] = [
            (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 8, false, 2, 2),
            (kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, 8, true, 2, 2),
            (kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange, 8, false, 2, 1),
            (kCVPixelFormatType_444YpCbCr8BiPlanarFullRange, 8, true, 1, 1),
            (kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, 10, false, 2, 2),
            (kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, 10, true, 2, 2),
            (kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, 10, false, 2, 1),
            (kCVPixelFormatType_422YpCbCr10BiPlanarFullRange, 10, true, 2, 1),
            (kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange, 10, false, 1, 1),
            (kCVPixelFormatType_444YpCbCr10BiPlanarFullRange, 10, true, 1, 1)
        ]
        for (format, depth, full, subX, subY) in expected {
            let layout = YCbCrBufferLayout(pixelFormat: format)
            #expect(layout == YCbCrBufferLayout(bitDepth: depth, isFullRange: full, chromaSubsamplingX: subX, chromaSubsamplingY: subY),
                    "Format \(format)")
        }
    }

    @Test func nonYCbCrFormatsAreRejected() {
        #expect(YCbCrBufferLayout(pixelFormat: kCVPixelFormatType_32BGRA) == nil)
        #expect(YCbCrBufferLayout(pixelFormat: kCVPixelFormatType_64RGBAHalf) == nil)
    }

    @Test func matricesCarryTheirLumaCoefficients() {
        #expect(YCbCrMatrix.rec709.coefficients == YCbCrCoefficients(kr: 0.2126, kb: 0.0722))
        #expect(YCbCrMatrix.rec601.coefficients == YCbCrCoefficients(kr: 0.299, kb: 0.114))
        #expect(YCbCrMatrix.rec2020.coefficients == YCbCrCoefficients(kr: 0.2627, kb: 0.0593))
        #expect(YCbCrMatrix.unknown.coefficients == YCbCrMatrix.rec709.coefficients, "Unlabeled HD video is Rec. 709")
    }
}

/// GPU kernels, checked against the BT.709 equations written out in Double. Without a Metal device
/// the suite is reported as skipped, not passed.
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct MetalColorKernelTests {
    /// Half-float storage rounds values in [0.5, 1) to a multiple of 2^-11, up to 0.25 of a 10-bit step.
    static let tolerance = 0.3 / 1023.0

    // MARK: Reference (plain Double, straight from the standard)

    struct Reference {
        var kr = 0.2126, kb = 0.0722

        /// Normalized Y'CbCr (Y' 0…1, Cb/Cr −0.5…0.5) from R'G'B'.
        func ycbcr(_ r: Double, _ g: Double, _ b: Double) -> (y: Double, cb: Double, cr: Double) {
            let y = kr * r + (1 - kr - kb) * g + kb * b
            return (y, (b - y) / (2 * (1 - kb)), (r - y) / (2 * (1 - kr)))
        }

        func rgb(y: Double, cb: Double, cr: Double) -> SIMD3<Double> {
            let r = y + 2 * (1 - kr) * cr, b = y + 2 * (1 - kb) * cb
            return SIMD3(r, (y - kr * r - kb * b) / (1 - kr - kb), b)
        }

        /// R'G'B' for 10-bit codes in video range.
        func videoRange10(y: Int, cb: Int, cr: Int) -> SIMD3<Double> {
            rgb(y: (Double(y) - 64) / 876, cb: (Double(cb) - 512) / 896, cr: (Double(cr) - 512) / 896)
        }

        func fullRange10(y: Int, cb: Int, cr: Int) -> SIMD3<Double> {
            rgb(y: Double(y) / 1023, cb: (Double(cb) - 512) / 1023, cr: (Double(cr) - 512) / 1023)
        }

        func videoRange8(y: Int, cb: Int, cr: Int) -> SIMD3<Double> {
            rgb(y: (Double(y) - 16) / 219, cb: (Double(cb) - 128) / 224, cr: (Double(cr) - 128) / 224)
        }
    }

    // MARK: Helpers

    static let kernels = try? VideoColorKernels()

    static func makeBuffer(
        format: OSType, width: Int, height: Int,
        luma: (Int, Int) -> Int, chroma: (Int, Int) -> (cb: Int, cr: Int)
    ) throws -> CVPixelBuffer {
        let layout = try #require(YCbCrBufferLayout(pixelFormat: format))
        var created: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, width, height, format, [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()
        ] as CFDictionary, &created)
        try #require(status == kCVReturnSuccess)
        let buffer = try #require(created)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0 ..< 2 {
            let base = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let planeWidth = CVPixelBufferGetWidthOfPlane(buffer, plane), planeHeight = CVPixelBufferGetHeightOfPlane(buffer, plane)
            for y in 0 ..< planeHeight {
                let row = base.advanced(by: y * stride)
                for x in 0 ..< planeWidth {
                    let samples = plane == 0 ? [luma(x, y)] : { let c = chroma(x, y); return [c.cb, c.cr] }()
                    for (index, code) in samples.enumerated() {
                        if layout.bitDepth > 8 {
                            row.assumingMemoryBound(to: UInt16.self)[x * samples.count + index] = UInt16(code << 6)
                        } else {
                            row.assumingMemoryBound(to: UInt8.self)[x * samples.count + index] = UInt8(code)
                        }
                    }
                }
            }
        }
        return buffer
    }

    /// Decodes a buffer on the GPU and reads the half-float result back.
    static func decode(_ buffer: CVPixelBuffer, matrix: YCbCrMatrix = .rec709) throws -> (width: Int, pixels: [SIMD3<Float>]) {
        let kernels = try #require(Self.kernels)
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let output = try kernels.makeWorkingTexture(width: width, height: height)
        let commandBuffer = try #require(kernels.runtime.queue.makeCommandBuffer())
        try kernels.decode(buffer, matrix: matrix, into: output, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed, "\(String(describing: commandBuffer.error))")
        return (width, readPixels(output))
    }

    static func readPixels(_ texture: MTLTexture) -> [SIMD3<Float>] {
        let width = texture.width, height = texture.height
        var halves = [Float16](repeating: 0, count: width * height * 4)
        texture.getBytes(&halves, bytesPerRow: width * 8, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return (0 ..< width * height).map { SIMD3(Float(halves[$0 * 4]), Float(halves[$0 * 4 + 1]), Float(halves[$0 * 4 + 2])) }
    }

    static func maxError(_ pixels: [SIMD3<Float>], width: Int, expected: (Int, Int) -> SIMD3<Double>, where include: (Int, Int) -> Bool = { _, _ in true }) -> Double {
        var worst = 0.0
        for (index, pixel) in pixels.enumerated() {
            let x = index % width, y = index / width
            guard include(x, y) else { continue }
            let want = expected(x, y)
            worst = max(worst, abs(Double(pixel.x) - want.x), abs(Double(pixel.y) - want.y), abs(Double(pixel.z) - want.z))
        }
        return worst
    }

    // MARK: Decode

    @Test func fullRangeTenBitGreyRampDecodesToNeutral() throws {
        // 1024-wide ramp: every 10-bit code once, neutral chroma. This is the S5 V-Log layout (xf22).
        let buffer = try Self.makeBuffer(format: kCVPixelFormatType_422YpCbCr10BiPlanarFullRange, width: 1024, height: 4,
                                         luma: { x, _ in x }, chroma: { _, _ in (512, 512) })
        let (width, pixels) = try Self.decode(buffer)
        let error = Self.maxError(pixels, width: width, expected: { x, _ in SIMD3(repeating: Double(x) / 1023) })
        #expect(error <= Self.tolerance, "Worst error \(error * 1023) of 1023 levels")
        #expect(pixels.allSatisfy { $0.x == $0.y && $0.y == $0.z }, "Neutral chroma must stay neutral")
    }

    @Test func videoRangeTenBitBlackAndWhite() throws {
        let buffer = try Self.makeBuffer(format: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, width: 4, height: 2,
                                         luma: { x, _ in x < 2 ? 64 : 940 }, chroma: { _, _ in (512, 512) })
        let (_, pixels) = try Self.decode(buffer)
        #expect(pixels[0] == SIMD3(repeating: 0) && pixels[3] == SIMD3(repeating: 1))
    }

    @Test(arguments: [
        (kCVPixelFormatType_422YpCbCr10BiPlanarFullRange, 10, true),
        (kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, 10, false),
        (kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, 10, false),
        (kCVPixelFormatType_444YpCbCr10BiPlanarFullRange, 10, true),
        (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 8, false),
        (kCVPixelFormatType_422YpCbCr8BiPlanarFullRange, 8, true)
    ] as [(OSType, Int, Bool)])
    func seventyFivePercentBarsMatchTheEquations(format: OSType, depth: Int, fullRange: Bool) throws {
        // Colors are built in R'G'B', encoded by the Double reference, then decoded by the GPU.
        let bars: [SIMD3<Double>] = [[0.75, 0.75, 0.75], [0.75, 0.75, 0], [0, 0.75, 0.75], [0, 0.75, 0],
                                     [0.75, 0, 0.75], [0.75, 0, 0], [0, 0, 0.75], [0, 0, 0]]
        let reference = Reference()
        func codes(_ rgb: SIMD3<Double>) -> (y: Int, cb: Int, cr: Int) {
            let c = reference.ycbcr(rgb.x, rgb.y, rgb.z)
            let top = Double((1 << depth) - 1), shift = Double(1 << (depth - 8))
            if fullRange {
                return (Int((c.y * top).rounded()), Int((c.cb * top + 128 * shift).rounded()), Int((c.cr * top + 128 * shift).rounded()))
            }
            return (Int((c.y * 219 * shift + 16 * shift).rounded()), Int((c.cb * 224 * shift + 128 * shift).rounded()),
                    Int((c.cr * 224 * shift + 128 * shift).rounded()))
        }
        let width = 64, barWidth = 8
        let subsampling = try #require(YCbCrBufferLayout(pixelFormat: format)).chromaSubsamplingX
        let buffer = try Self.makeBuffer(format: format, width: width, height: 4,
                                         luma: { x, _ in codes(bars[x / barWidth]).y },
                                         chroma: { x, _ in let c = codes(bars[min(7, (x * subsampling) / barWidth)]); return (c.cb, c.cr) })
        let (_, pixels) = try Self.decode(buffer)
        // Away from the bar edges, chroma is flat and the result must match the quantized codes exactly…
        func decodeExpected(_ c: (y: Int, cb: Int, cr: Int)) -> SIMD3<Double> {
            if depth == 8 {
                return fullRange
                    ? reference.rgb(y: Double(c.y) / 255, cb: (Double(c.cb) - 128) / 255, cr: (Double(c.cr) - 128) / 255)
                    : reference.videoRange8(y: c.y, cb: c.cb, cr: c.cr)
            }
            return fullRange ? reference.fullRange10(y: c.y, cb: c.cb, cr: c.cr) : reference.videoRange10(y: c.y, cb: c.cb, cr: c.cr)
        }
        let interior = { (x: Int, _: Int) in x % barWidth >= 2 && x % barWidth < barWidth - 2 }
        let exact = Self.maxError(pixels, width: width, expected: { x, _ in decodeExpected(codes(bars[x / barWidth])) }, where: interior)
        #expect(exact <= Self.tolerance, "Worst error \(exact * 1023) of 1023 levels")
        // …and, because 8-bit codes are coarse, within a few levels of the colors we started from.
        let coarse = Self.maxError(pixels, width: width, expected: { x, _ in bars[x / barWidth] }, where: interior)
        #expect(coarse <= (depth == 8 ? 6.0 / 255 : 3.0 / 1023), "Worst error against the source colors \(coarse * 1023) of 1023")
    }

    @Test func chromaIsUpsampledBetweenSamplesWithLeftSiting() throws {
        // 4:2:2: chroma sample i sits on luma pixel 2i, so pixel 2i+1 is the mean of samples i and i+1.
        let buffer = try Self.makeBuffer(format: kCVPixelFormatType_422YpCbCr10BiPlanarFullRange, width: 32, height: 2,
                                         luma: { _, _ in 512 }, chroma: { x, _ in (400 + x * 20, 600 - x * 10) })
        let (width, pixels) = try Self.decode(buffer)
        let reference = Reference()
        func chromaAt(_ x: Int) -> (cb: Double, cr: Double) {
            let i = x / 2, f = Double(x % 2) / 2
            let next = min(i + 1, 15)
            return (Double(400 + i * 20) * (1 - f) + Double(400 + next * 20) * f, Double(600 - i * 10) * (1 - f) + Double(600 - next * 10) * f)
        }
        let error = Self.maxError(pixels, width: width, expected: { x, _ in
            let c = chromaAt(x)
            return reference.rgb(y: 512.0 / 1023, cb: (c.cb - 512) / 1023, cr: (c.cr - 512) / 1023)
        })
        #expect(error <= Self.tolerance, "Worst error \(error * 1023) of 1023 levels")
    }

    @Test func fourTwoZeroChromaSitsHalfARowBelowItsLumaRow() throws {
        // H.264 4:2:0 'left' siting: chroma row j is at luma y = 2j + 0.5.
        let buffer = try Self.makeBuffer(format: kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, width: 8, height: 16,
                                         luma: { _, _ in 512 }, chroma: { _, y in (300 + y * 40, 512) })
        let (width, pixels) = try Self.decode(buffer)
        let reference = Reference()
        let error = Self.maxError(pixels, width: width, expected: { _, y in
            let position = (Double(y) - 0.5) / 2
            let low = max(0, Int(position.rounded(.down))), high = min(7, low + 1)
            let f = max(0, position - Double(low))
            let cb = Double(300 + low * 40) * (1 - f) + Double(300 + high * 40) * f
            return reference.rgb(y: 512.0 / 1023, cb: (cb - 512) / 1023, cr: 0)
        })
        #expect(error <= Self.tolerance, "Worst error \(error * 1023) of 1023 levels")
    }

    @Test func rec2020MatrixChangesTheCoefficients() throws {
        let buffer = try Self.makeBuffer(format: kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange, width: 4, height: 2,
                                         luma: { _, _ in 400 }, chroma: { _, _ in (700, 300) })
        let (_, pixels) = try Self.decode(buffer, matrix: .rec2020)
        let want = Reference(kr: 0.2627, kb: 0.0593).videoRange10(y: 400, cb: 700, cr: 300)
        let error = max(abs(Double(pixels[0].x) - want.x), abs(Double(pixels[0].y) - want.y), abs(Double(pixels[0].z) - want.z))
        #expect(error <= Self.tolerance)
        let as709 = Reference().videoRange10(y: 400, cb: 700, cr: 300)
        #expect(abs(as709.y - want.y) > 0.01, "The two matrices must differ for this color to prove anything")
    }

    /// Task 13.2: 75% colour bars encoded with the BT.2020 coefficients (Apple Log's matrix) in
    /// video-range 10-bit 4:2:2, the layout the iPhone writes. Decoding with `.rec2020` gives the
    /// bars back within code rounding; decoding them as 709 would not.
    @Test func rec2020BarsDecodeWithTheRec2020Matrix() throws {
        let reference = Reference(kr: 0.2627, kb: 0.0593)
        let bars: [SIMD3<Double>] = [[0.75, 0.75, 0.75], [0.75, 0.75, 0], [0, 0.75, 0.75], [0, 0.75, 0],
                                     [0.75, 0, 0.75], [0.75, 0, 0], [0, 0, 0.75], [0, 0, 0]]
        // Codes in Double first, rounded once, as an encoder would.
        let codes = bars.map { bar -> (y: Int, cb: Int, cr: Int) in
            let (r, g, b) = (bar.x, bar.y, bar.z)
            let y = reference.kr * r + (1 - reference.kr - reference.kb) * g + reference.kb * b
            let cb = (b - y) / (2 * (1 - reference.kb)), cr = (r - y) / (2 * (1 - reference.kr))
            return (Int((64 + 876 * y).rounded()), Int((512 + 896 * cb).rounded()), Int((512 + 896 * cr).rounded()))
        }
        let barWidth = 8
        let buffer = try Self.makeBuffer(format: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, width: barWidth * bars.count, height: 2,
                                         luma: { x, _ in codes[x / barWidth].y },
                                         chroma: { x, _ in let c = codes[x * 2 / barWidth]; return (c.cb, c.cr) })
        let (_, pixels) = try Self.decode(buffer, matrix: .rec2020)
        let (_, as709) = try Self.decode(buffer, matrix: .rec709)
        var exact = 0.0, toBars = 0.0, misread = 0.0
        for (index, code) in codes.enumerated() {
            let x = index * barWidth + barWidth / 2 // Mid-bar, where 4:2:2 chroma is constant.
            let decoded = SIMD3<Double>(Double(pixels[x].x), Double(pixels[x].y), Double(pixels[x].z))
            let want = reference.videoRange10(y: code.y, cb: code.cb, cr: code.cr)
            exact = max(exact, abs(decoded - want).max())
            toBars = max(toBars, abs(decoded - bars[index]).max())
            misread = max(misread, abs(SIMD3<Double>(Double(as709[x].x), Double(as709[x].y), Double(as709[x].z)) - bars[index]).max())
        }
        #expect(exact <= Self.tolerance, "Against the codes' exact R'G'B': \(exact * 1023) of 1023")
        #expect(toBars <= 2.0 / 1023, "Against the bars: \(toBars * 1023) of 1023 (code rounding only)")
        #expect(misread > 0.02, "Decoding 2020 bars as 709 must visibly misread them (\(misread))")
    }

    // MARK: Encode

    @Test func encodeThenDecodeKeepsTenBitCodes() throws {
        // Smooth content (linear luma and chroma ramps) survives 4:2:2 downsampling exactly.
        let width = 256, height = 4
        let source = try Self.makeBuffer(format: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, width: width, height: height,
                                         luma: { x, _ in 64 + x * 3 }, chroma: { x, _ in (400 + x * 2, 620 - x * 2) })
        let kernels = try #require(Self.kernels)
        let working = try kernels.makeWorkingTexture(width: width, height: height)
        var created: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, [
            kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()
        ] as CFDictionary, &created)
        let output = try #require(created)

        let commandBuffer = try #require(kernels.runtime.queue.makeCommandBuffer())
        try kernels.decode(source, matrix: .rec709, into: working, commandBuffer: commandBuffer)
        try kernels.encodeVideoRange422(working, matrix: .rec709, into: output, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed, "\(String(describing: commandBuffer.error))")

        CVPixelBufferLockBaseAddress(output, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
        var worstLuma = 0, worstChroma = 0
        let lumaBase = try #require(CVPixelBufferGetBaseAddressOfPlane(output, 0)), lumaStride = CVPixelBufferGetBytesPerRowOfPlane(output, 0)
        let chromaBase = try #require(CVPixelBufferGetBaseAddressOfPlane(output, 1)), chromaStride = CVPixelBufferGetBytesPerRowOfPlane(output, 1)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let code = Int(lumaBase.advanced(by: y * lumaStride).assumingMemoryBound(to: UInt16.self)[x] >> 6)
                worstLuma = max(worstLuma, abs(code - (64 + x * 3)))
            }
            for x in 1 ..< width / 2 - 1 { // The edge samples see clamped neighbours.
                let row = chromaBase.advanced(by: y * chromaStride).assumingMemoryBound(to: UInt16.self)
                let cb = Int(row[x * 2] >> 6), cr = Int(row[x * 2 + 1] >> 6)
                worstChroma = max(worstChroma, abs(cb - (400 + 2 * x)), abs(cr - (620 - 2 * x)))
            }
        }
        #expect(worstLuma <= 1 && worstChroma <= 1, "Round trip changed codes by \(worstLuma) (luma) and \(worstChroma) (chroma)")
    }

    @Test func encodeClampsToTheCodesProResAllows() throws {
        let kernels = try #require(Self.kernels)
        let working = try kernels.makeWorkingTexture(width: 4, height: 2)
        // Blacker than black, whiter than white, and a saturated color past the gamut.
        var halves: [Float16] = [-0.2, -0.2, -0.2, 1, 1.5, 1.5, 1.5, 1, 1.4, -0.3, 0.2, 1, 0, 0, 0, 1]
        halves += halves
        working.replace(region: MTLRegionMake2D(0, 0, 4, 1), mipmapLevel: 0, withBytes: halves, bytesPerRow: 32)
        working.replace(region: MTLRegionMake2D(0, 1, 4, 1), mipmapLevel: 0, withBytes: halves, bytesPerRow: 32)
        var created: CVPixelBuffer?
        CVPixelBufferCreate(nil, 4, 2, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, [
            kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()
        ] as CFDictionary, &created)
        let output = try #require(created)
        let commandBuffer = try #require(kernels.runtime.queue.makeCommandBuffer())
        try kernels.encodeVideoRange422(working, matrix: .rec709, into: output, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        CVPixelBufferLockBaseAddress(output, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
        let luma = try #require(CVPixelBufferGetBaseAddressOfPlane(output, 0)).assumingMemoryBound(to: UInt16.self)
        let chroma = try #require(CVPixelBufferGetBaseAddressOfPlane(output, 1)).assumingMemoryBound(to: UInt16.self)
        let codes = (0 ..< 4).map { Int(luma[$0] >> 6) } + (0 ..< 4).map { Int(chroma[$0] >> 6) }
        #expect(codes.allSatisfy { (4 ... 1019).contains($0) }, "Codes \(codes)")
        #expect(codes[0] == 4 && codes[1] == 1019, "Super-black and super-white pin to the legal ends: \(codes)")
    }

    // MARK: Fit

    @Test func fitLetterboxesWithBlackAndKeepsEqualSizesUntouched() throws {
        let kernels = try #require(Self.kernels)
        // A 40×20 (2:1) gradient into a 40×40 frame: 20 rows of picture centered between black bars.
        let source = try kernels.makeWorkingTexture(width: 40, height: 20)
        var halves = [Float16](repeating: 1, count: 40 * 20 * 4)
        for y in 0 ..< 20 { for x in 0 ..< 40 { for c in 0 ..< 3 { halves[(y * 40 + x) * 4 + c] = Float16(Float(x) / 39) } } }
        source.replace(region: MTLRegionMake2D(0, 0, 40, 20), mipmapLevel: 0, withBytes: halves, bytesPerRow: 40 * 8)

        let square = try kernels.makeWorkingTexture(width: 40, height: 40)
        let same = try kernels.makeWorkingTexture(width: 40, height: 20)
        let commandBuffer = try #require(kernels.runtime.queue.makeCommandBuffer())
        try kernels.fit(source, into: square, commandBuffer: commandBuffer)
        try kernels.fit(source, into: same, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let letterboxed = Self.readPixels(square)
        #expect((0 ..< 40).allSatisfy { x in letterboxed[2 * 40 + x] == .zero && letterboxed[37 * 40 + x] == .zero }, "Bars are black")
        for x in [0, 10, 20, 39] { #expect(abs(letterboxed[20 * 40 + x].x - Float(x) / 39) < 0.01, "Picture column \(x)") }
        #expect(Self.readPixels(same) == Self.readPixels(source), "Same-size fit is exact")
    }

    @Test func workingTexturesAreHalfFloatAndGPUWritable() throws {
        let texture = try #require(Self.kernels).makeWorkingTexture(width: 8, height: 8)
        #expect(texture.pixelFormat == .rgba16Float && texture.usage.contains(.shaderRead) && texture.usage.contains(.shaderWrite))
    }
}
