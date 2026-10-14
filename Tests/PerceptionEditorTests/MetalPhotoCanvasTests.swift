import CoreGraphics
import CoreImage
import Metal
import Testing
@testable import PerceptionEditor

struct MetalPhotoCanvasTests {
    @Test func fitCentersAndPreservesAspect() {
        let wide = PhotoCanvasLayout.fitRect(imageSize: CGSize(width: 300, height: 100), in: CGSize(width: 600, height: 600))
        #expect(wide == CGRect(x: 0, y: 200, width: 600, height: 200))

        let tall = PhotoCanvasLayout.fitRect(imageSize: CGSize(width: 100, height: 300), in: CGSize(width: 600, height: 600))
        #expect(tall == CGRect(x: 200, y: 0, width: 200, height: 600))

        let upscaled = PhotoCanvasLayout.fitRect(imageSize: CGSize(width: 10, height: 10), in: CGSize(width: 40, height: 20))
        #expect(upscaled == CGRect(x: 10, y: 0, width: 20, height: 20))
    }

    @Test func degenerateSizesGiveAnEmptyRect() {
        #expect(PhotoCanvasLayout.fitRect(imageSize: .zero, in: CGSize(width: 10, height: 10)).isEmpty)
        #expect(PhotoCanvasLayout.fitRect(imageSize: CGSize(width: 10, height: 10), in: .zero).isEmpty)
    }

    /// Top half red, bottom half blue, in a 2:1 image drawn into a square canvas: the photo must keep
    /// its orientation, sit centered, and leave the margins transparent.
    @Test func composedCanvasKeepsOrientationAndMargins() throws {
        let image = try #require(Self.twoToneImage(width: 40, height: 20))
        let canvas = CGSize(width: 40, height: 40)
        let frame = PhotoCanvasRenderer.composed(CIImage(cgImage: image), canvasSize: canvas)
        #expect(frame.extent == CGRect(origin: .zero, size: canvas))

        let context = CIContext(options: [.useSoftwareRenderer: true])
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var pixels = [UInt8](repeating: 0, count: 40 * 40 * 4)
        context.render(frame, toBitmap: &pixels, rowBytes: 40 * 4, bounds: frame.extent, format: .RGBA8, colorSpace: space)

        func pixel(_ x: Int, _ y: Int) -> [UInt8] {   // y counted from the top, as bitmaps are
            let i = (y * 40 + x) * 4
            return Array(pixels[i ..< i + 4])
        }
        let top = pixel(20, 15), bottom = pixel(20, 25)
        #expect(top[0] > 245 && top[2] < 10 && top[3] == 255)      // red half stays on top
        #expect(bottom[0] < 10 && bottom[2] > 245 && bottom[3] == 255)  // blue half stays below
        #expect(pixel(20, 2)[3] == 0)                      // margin above the photo
        #expect(pixel(20, 37)[3] == 0)                     // margin below the photo
    }

    /// The real GPU path: Core Image into a Metal texture, read back. Skipped where no Metal device exists.
    @Test(.enabled(if: PhotoCanvasRenderer.shared.device != nil)) func gpuDrawKeepsOrientationAndMargins() throws {
        let renderer = PhotoCanvasRenderer.shared
        let device = try #require(renderer.device)
        let queue = try #require(renderer.queue)
        let image = try #require(Self.twoToneImage(width: 40, height: 20))

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 40, height: 40, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let buffer = try #require(queue.makeCommandBuffer())
        try renderer.draw(CIImage(cgImage: image), into: texture, colorSpace: CGColorSpace(name: CGColorSpace.sRGB), buffer: buffer)
        buffer.commit()
        buffer.waitUntilCompleted()
        #expect(buffer.error == nil)

        var pixels = [UInt8](repeating: 0, count: 40 * 40 * 4)   // BGRA, row 0 is the top
        texture.getBytes(&pixels, bytesPerRow: 40 * 4, from: MTLRegionMake2D(0, 0, 40, 40), mipmapLevel: 0)
        func bgra(_ x: Int, _ y: Int) -> [UInt8] {
            let i = (y * 40 + x) * 4
            return Array(pixels[i ..< i + 4])
        }
        let top = bgra(20, 15), bottom = bgra(20, 25)
        #expect(top[2] > 245 && top[0] < 10)        // red on top
        #expect(bottom[0] > 245 && bottom[2] < 10)  // blue below
        #expect(bgra(20, 2)[3] == 0 && bgra(20, 37)[3] == 0)
    }

    private static func twoToneImage(width: Int, height: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // CGContext origin is bottom-left: fill the top half red, the bottom half blue.
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: height / 2, width: width, height: height - height / 2))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        return ctx.makeImage()
    }
}
