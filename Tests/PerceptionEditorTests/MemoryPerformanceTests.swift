import AppKit
import Darwin
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PerceptionEditor

/// Run alone: PME_RUN_MEMORY_PROFILE=1 ./scripts/test.sh --filter MemoryPerformanceTests
/// A fresh process is needed for meaningful footprint/peak readings.
@Suite(.serialized)
struct MemoryPerformanceTests {
    private static var enabled: Bool { ProcessInfo.processInfo.environment["PME_RUN_MEMORY_PROFILE"] == "1" }

    private func snapshot(_ label: String) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if status == KERN_SUCCESS {
            print("RAM_PROFILE \(label): footprint=\(Double(info.phys_footprint) / 1_048_576) MiB peak=\(Double(info.ledger_phys_footprint_peak) / 1_048_576) MiB")
        }
    }

    private func milliseconds(_ start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: ContinuousClock().now).components
        return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    @Test(.enabled(if: Self.enabled))
    func profileRAWWorkflowAndCheckBudgetedPixels() async throws {
        let env = ProcessInfo.processInfo.environment
        let folder = URL(fileURLWithPath: env["PME_RAW_SAMPLE_DIR"] ?? "/Volumes/ExSSD1/110_PANA")
        let urls = Array(try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "rw2" }.sorted { $0.path < $1.path }.prefix(16))
        #expect(urls.count >= 4)
        guard urls.count >= 4 else { return }
        let budgetText = env["PME_RENDER_MEMORY_TARGET_MB"] ?? "256"
        let budget = budgetText == "none" ? nil : Int(budgetText)
        let fullBudgetText = env["PME_FULL_RES_MEMORY_TARGET_MB"] ?? "128"
        let fullBudget = fullBudgetText == "none" ? nil : Int(fullBudgetText)
        print("RAM_PROFILE context target=\(budgetText) MB; focus/export target=\(fullBudgetText) MB; RAW samples=\(urls.count)")
        snapshot("baseline")
        let thumbs = PhotoRenderer(workingCacheLimit: 0, memoryTargetMB: budget == nil ? nil : 32)
        let renderer = PhotoRenderer(memoryTargetMB: budget)
        let focus = PhotoRenderer(workingCacheLimit: 0, memoryTargetMB: fullBudget)
        let exporter = PhotoRenderer(workingCacheLimit: 0, memoryTargetMB: fullBudget)
        var thumbnails: [CGImage] = []
        var cullImages: [CGImage] = []
        var preview: CGImage?
        var original: CGImage?
        var focusImage: CGImage?
        for url in urls { thumbnails.append(try #require(await thumbs.thumbnail(url: url, adjustments: .neutral)).cgImage) }
        snapshot("16 thumbnails")
        // Deliberately retain ten, matching the earlier diagnostic even though the app now keeps six.
        for url in urls.prefix(10) {
            cullImages.append(try #require(autoreleasepool { PhotoSourceLoader.loadCullPreview(url) }))
        }
        snapshot("plus 10 cull previews")
        let clock = ContinuousClock()
        var start = clock.now
        for url in urls.prefix(4) {
            preview = try #require(await renderer.preview(url: url, adjustments: .neutral)).edited.cgImage
            original = try #require(await renderer.original(url: url)).cgImage
        }
        print("RAM_TIMING four cold working sources=\(milliseconds(start)) ms")
        snapshot("four working sources and before/after")
        var warm: [Double] = []
        for index in 0..<15 {
            start = clock.now
            preview = try #require(await renderer.preview(url: urls[3], adjustments: PhotoAdjustments(exposure: Double(index) / 20))).edited.cgImage
            warm.append(milliseconds(start))
        }
        print("RAM_TIMING warm preview median=\(warm.sorted()[warm.count / 2]) ms max=\(warm.max()!) ms")
        start = clock.now
        focusImage = try #require(await focus.focusRegion(url: urls[3], adjustments: .neutral,
            center: CGPoint(x: 0.5, y: 0.5), viewportPixels: CGSize(width: 1800, height: 1200))).image.cgImage
        print("RAM_TIMING initial focus=\(milliseconds(start)) ms")
        snapshot("100 percent focus")
        var pans: [Double] = []
        for index in 0..<10 {
            start = clock.now
            focusImage = try #require(await focus.focusRegion(url: urls[3], adjustments: .neutral,
                center: CGPoint(x: 0.4 + Double(index) / 100, y: 0.5), viewportPixels: CGSize(width: 1800, height: 1200))).image.cgImage
            pans.append(milliseconds(start))
        }
        print("RAM_TIMING focus pan median=\(pans.sorted()[pans.count / 2]) ms max=\(pans.max()!) ms")
        focusImage = nil
        await focus.releaseFullResolution()
        try await Task.sleep(for: .seconds(1))
        snapshot("after leaving focus")
        let temp = try TempDirectory()
        start = clock.now
        try await exporter.export(url: urls[3], adjustments: .neutral, to: temp.url.appendingPathComponent("export.jpg"), type: .jpeg)
        print("RAM_TIMING full JPEG export=\(milliseconds(start)) ms")
        try await Task.sleep(for: .seconds(1))
        snapshot("after export")
        withExtendedLifetime((thumbnails, cullImages, preview, original, focusImage)) {}

        // A reduced allocation target must preserve the image, including RAW highlight headroom.
        let reference = PhotoRenderer(workingCacheLimit: 0, memoryTargetMB: nil)
        var adjustments = PhotoAdjustments(exposure: -0.7, contrast: 0.1, highlights: -0.3, shadows: 0.2)
        adjustments.raw.temperature = 5200
        let expected = try #require(await reference.preview(url: urls[0], adjustments: adjustments)).edited.cgImage
        let actual = try #require(await renderer.preview(url: urls[0], adjustments: adjustments)).edited.cgImage
        #expect(expected.width == actual.width && expected.height == actual.height)
        let expectedBytes = try pixels(expected)
        let actualBytes = try pixels(actual)
        let maximumDifference = zip(expectedBytes, actualBytes).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
        #expect(maximumDifference <= 1, "Budgeted RAW rendering changed pixels by \(maximumDifference)/255")
        print("RAM_QUALITY max RAW preview channel difference=\(maximumDifference)/255")
    }
}
