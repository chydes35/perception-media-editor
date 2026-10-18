# Video proxy pipeline (ProRes 422 Proxy, originals for export)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

Status: active (implemented; Runtime/UI walkthrough passed on the redesign build, re-check on this branch pending)
Roadmap item: [V1.0 — Proxy generation and original-media export](../docs/ROADMAP.md) (pulled forward as the prerequisite for V0.3 video work)
Owner: video engine

**Goal:** Every imported video gets a ProRes 422 Proxy that the timeline and source viewer play from, while anything that renders deliverables resolves back to the camera originals.

**Architecture:** Proxies are a disposable, content-addressed cache, like thumbnails and waveforms. Each proxy is keyed by a fingerprint of the source bytes, so `.pmedit` files don't change and there is no schema bump. A serial `ProxyStore` (main actor, status only) runs one `ProxyGenerator` job at a time off the main actor using AVAssetReader → AVAssetWriter. `TimelineCompositionService` takes a `MediaQuality` (`.preview` / `.export`) plus the ready proxy URLs. Preview uses a proxy when one exists; export always uses originals.

**Tech Stack:** Swift 6.1, AVFoundation (AVAssetReader/AVAssetWriter, AVMutableComposition), CryptoKit, Swift Testing. No new dependencies.

**Spec:** This plan. Evidence comes from the 2026-10-15 video evaluation on the target 8 GB M1 using Lumix S5 `P1107157.MOV` (H.264 High 4:2:2, 10-bit, 3840×2160, 23.976 fps, ~150 Mbit/s):

| Measurement on the 8 GB M1 | Result |
| --- | --- |
| VideoToolbox hardware decode of the original | Not supported. ffmpeg's VT path emitted 20 of 240 frames. |
| AVFoundation decode to `x422` (10-bit 4:2:2 biplanar) | 45 fps (1.9× realtime) |
| AVFoundation decode to 32BGRA | 12 fps (0.5× realtime). Never ask the reader for BGRA. |
| AVAssetReader → AVAssetWriter, ProRes 422 Proxy at 1920×1080 | 40.8 fps (1.7× realtime), 44 MB per 10 s |
| AVFoundation decode of that proxy | 345 fps |

## Global Constraints

- macOS 15+, Swift 6.1, Apple Silicon. No third-party packages; `Package.swift` stays unchanged.
- Never write to, move, or lock original media. A proxy is always a new file in the proxy directory.
- `.pmedit` schema stays at **10**. Proxies are not project data (see `docs/DATA_MODEL.md`: caches are disposable).
- Proxy format: ProRes 422 Proxy (`AVVideoCodecType.proRes422Proxy`), video only, aspect-fit inside 1920×1080, even dimensions, never upscaled. It keeps the source's first presentation timestamp, frame count, preferred transform, and color primaries/transfer/matrix.
- Read source frames as `kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange`, never 32BGRA.
- Only one proxy job runs at a time (8 GB machine; decode already uses every core). Generation never runs on the main actor.
- A proxy becomes visible only after it validates. It is written to `<key>.partial.mov`, checked, and then moved to `<key>.mov`. Cancellation or failure leaves no `.partial.mov` behind.
- Disk guard: before starting, require free space ≥ estimated proxy size + 2 GiB. The estimate is 4.5 MB/s × duration × (proxy pixels ÷ 1920×1080).
- Audio is never proxied. Preview audio always comes from the original file.
- Export quality ignores proxies completely, even when proxy URLs are passed in.
- Default proxy directory: `~/Library/Application Support/Perception Media Editor/Proxy Cache`. The UserDefaults key `perceptionEditor.proxyDirectory` (a path) overrides it. **Product decision to confirm:** at about 16 GB per hour of 1080p proxy, the owner may want this on the external SSD instead.

## Review Focus

1. **The proxy for one clip becomes ready while the timeline is playing.** The rebuild must keep the playhead and play/pause state (it reuses `rebuildTimelinePlayback`'s retention logic), not jump to 0. Covered by Task 6's `proxyReadyRebuildKeepsPosition`.
2. **A timeline mixing proxied and unproxied clips.** It must render at one size with no letterboxing glitches or crash. Covered by Task 4's `mixedTimelineRendersAtProxySize`.
3. **The proxy file is deleted out from under a project** (the user clears the cache folder). Playback must fall back to the original silently, and the store must regenerate the proxy. Covered by Task 4's `missingProxyFileFallsBackToOriginal` and Task 5's `deletedProxyIsRegenerated`.
4. **The same card clip is imported twice, or moved and then relinked.** The proxy is reused, not regenerated. Covered by Task 2's `sameBytesAtDifferentPathsShareAKey` and Task 5's `movedSourceReusesProxy`.
5. **The disk is nearly full.** The job fails with a readable message, leaves no partial file, and the original stays playable. Covered by Task 5's `insufficientSpaceFailsWithoutWriting`.

---

## File structure

| File | Responsibility |
| --- | --- |
| Create `Sources/PerceptionEditor/ProxyFingerprint.swift` | Content key for a source file (size + first/last 1 MiB, SHA-256) |
| Create `Sources/PerceptionEditor/ProxyGenerator.swift` | One proxy transcode: size rule, color tags, cancellation, validation, atomic publish |
| Create `Sources/PerceptionEditor/ProxyStore.swift` | Main-actor status map, serial queue, disk guard, directory, reuse, cancel, delete-all |
| Modify `Sources/PerceptionEditor/TimelineCompositionService.swift` | `MediaQuality`, per-clip source resolution, render size for proxies, `usedProxyCount` |
| Modify `Sources/PerceptionEditor/EditorStore.swift` | Owns `ProxyStore`; enqueue on import/open/relink; proxy-aware source viewer and timeline; `usesProxiesForPlayback` |
| Modify `Sources/PerceptionEditor/EditorStore+Ingest.swift` | Enqueue proxies for ingested video |
| Modify `Sources/PerceptionEditor/VideoWorkspace.swift` | Proxy badge on media cards; Proxies toggle |
| Create `Tests/PerceptionEditorTests/VideoTestSupport.swift` | `writeTestMovie`, `waitForProxy` helpers |
| Create `Tests/PerceptionEditorTests/ProxyGeneratorTests.swift`, `ProxyStoreTests.swift`, `TimelineProxyCompositionTests.swift`, `VideoProxyWorkflowTests.swift`, `RealVideoProxyTests.swift` | Tests per component plus a real-footage gate |
| Create `docs/decisions/2026-10-15-video-proxies.md`; modify `docs/DATA_MODEL.md`, `docs/CURRENT_STATUS.md`, `docs/ROADMAP.md`, `docs/PERFORMANCE_TARGETS.md` | Decision record and contract updates |

Run tests with `./scripts/test.sh --filter <Suite>`. The full gate is `./scripts/qa.sh`. Branch from `main` (not `wb-latency`) before Task 1.

---

### Task 1: Test movie fixture and fingerprint

**Files:**
- Create: `Tests/PerceptionEditorTests/VideoTestSupport.swift`
- Create: `Sources/PerceptionEditor/ProxyFingerprint.swift`
- Test: `Tests/PerceptionEditorTests/ProxyGeneratorTests.swift` (fingerprint suite lives here too)

**Interfaces:**
- Produces: `func writeTestMovie(to: URL, frames: Int = 24, width: Int = 640, height: Int = 360) async throws -> URL` (test-only, ProRes 422, 24000/1001 fps, Rec.709 tags, starts at time 0)
- Produces: `enum ProxyFingerprint { static func key(for url: URL) throws -> String }` (64 lowercase hex characters)

- [ ] **Step 1: Write the fixture helper**

```swift
// Tests/PerceptionEditorTests/VideoTestSupport.swift
@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import PerceptionEditor

/// Writes a small ProRes 422 movie whose frames step from black to white, tagged Rec. 709,
/// at 23.976 fps, so proxy tests exercise the same frame timing as Lumix footage.
@discardableResult
func writeTestMovie(to url: URL, frames: Int = 24, width: Int = 640, height: Int = 360) async throws -> URL {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.proRes422,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoColorPropertiesKey: [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
        ]
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height
    ])
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    writer.startSession(atSourceTime: .zero)

    let frameDuration = CMTime(value: 1001, timescale: 24000)
    for index in 0 ..< frames {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
        guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
        var created: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created)
        guard let buffer = created else { throw CocoaError(.fileWriteUnknown) }
        CVPixelBufferLockBaseAddress(buffer, [])
        let shade = Int32(index * 255 / max(1, frames - 1))
        memset(CVPixelBufferGetBaseAddress(buffer), shade, CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard adaptor.append(buffer, withPresentationTime: CMTimeMultiply(frameDuration, multiplier: Int32(index))) else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    return url
}
```


- [ ] **Step 2: Write the failing fingerprint tests**

```swift
// Tests/PerceptionEditorTests/ProxyGeneratorTests.swift
@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import PerceptionEditor

struct ProxyFingerprintTests {
    @Test func sameBytesAtDifferentPathsShareAKey() throws {
        let temp = try TempDirectory()
        let a = try temp.file("card/P1.MOV", bytes: 3_000_000, seed: 7)
        let b = temp.url.appendingPathComponent("shoot/P1.MOV")
        try FileManager.default.createDirectory(at: b.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: a, to: b)
        #expect(try ProxyFingerprint.key(for: a) == ProxyFingerprint.key(for: b))
    }

    @Test func changedTailChangesTheKey() throws {
        let temp = try TempDirectory()
        let url = try temp.file("P1.MOV", bytes: 3_000_000, seed: 7)
        let before = try ProxyFingerprint.key(for: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: 2_999_999)
        try handle.write(contentsOf: Data([0xAB]))
        try handle.close()
        #expect(try ProxyFingerprint.key(for: url) != before)
    }

    @Test func smallFilesAndMissingFiles() throws {
        let temp = try TempDirectory()
        let tiny = try temp.file("tiny.mov", bytes: 10, seed: 1)
        #expect(try ProxyFingerprint.key(for: tiny).count == 64)
        #expect(throws: (any Error).self) { try ProxyFingerprint.key(for: temp.url.appendingPathComponent("gone.mov")) }
    }
}
```

- [ ] **Step 3: Run the tests and confirm they fail**

Run: `./scripts/test.sh --filter ProxyFingerprintTests`
Expected: compile failure, `cannot find 'ProxyFingerprint' in scope`.

- [ ] **Step 4: Implement the fingerprint**

```swift
// Sources/PerceptionEditor/ProxyFingerprint.swift
import CryptoKit
import Foundation

/// Identifies a source file by content, not path, so a clip that is copied, moved, or relinked
/// keeps its proxy. Reads at most 2 MiB: the size plus the first and last mebibyte.
enum ProxyFingerprint {
    static let sampleBytes = 1_048_576

    static func key(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        var hasher = SHA256()
        hasher.update(data: Data("\(size)|".utf8))
        try handle.seek(toOffset: 0)
        hasher.update(data: try handle.read(upToCount: sampleBytes) ?? Data())
        if size > UInt64(sampleBytes) {
            try handle.seek(toOffset: size - UInt64(min(UInt64(sampleBytes), size - UInt64(sampleBytes))))
            hasher.update(data: try handle.readToEnd() ?? Data())
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
```

- [ ] **Step 5: Run the tests and confirm they pass**

Run: `./scripts/test.sh --filter ProxyFingerprintTests`
Expected: 3 tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/PerceptionEditor/ProxyFingerprint.swift Tests/PerceptionEditorTests/VideoTestSupport.swift Tests/PerceptionEditorTests/ProxyGeneratorTests.swift
git commit -m "Add content fingerprint and test movie fixture for video proxies"
```

---

### Task 2: ProxyGenerator — one validated transcode

**Files:**
- Create: `Sources/PerceptionEditor/ProxyGenerator.swift`
- Test: `Tests/PerceptionEditorTests/ProxyGeneratorTests.swift`

**Interfaces:**
- Consumes: `writeTestMovie` (Task 1)
- Produces:
  - `struct ProxyInfo: Equatable, Sendable { var url: URL; var frameCount: Int; var pixelWidth: Int; var pixelHeight: Int }`
  - `enum ProxyError: LocalizedError, Equatable { case noVideoTrack, readFailed(String), writeFailed(String), validationFailed(String), insufficientSpace(neededBytes: Int64, availableBytes: Int64) }`
  - `enum ProxyGenerator` with:
    - `static let defaultMaximumSize: CGSize` (1920×1080)
    - `static let bytesPerSecondAt1080p: Double` (4_500_000)
    - `static func proxySize(for: CGSize, maximum: CGSize = defaultMaximumSize) -> CGSize`
    - `static func estimatedBytes(durationSeconds: Double, proxySize: CGSize) -> Int64`
    - `static func generate(source: URL, destination: URL, maximumSize: CGSize = defaultMaximumSize, progress: @Sendable (Double) -> Void = { _ in }) async throws -> ProxyInfo`
    - `static func frameCount(at: URL) async throws -> Int`

- [ ] **Step 1: Write the failing tests**

```swift
struct ProxyGeneratorTests {
    @Test func sizeFitsInsideTheLimitWithEvenDimensionsAndNeverUpscales() {
        #expect(ProxyGenerator.proxySize(for: CGSize(width: 3840, height: 2160)) == CGSize(width: 1920, height: 1080))
        #expect(ProxyGenerator.proxySize(for: CGSize(width: 4096, height: 2160)) == CGSize(width: 1920, height: 1012))
        #expect(ProxyGenerator.proxySize(for: CGSize(width: 2160, height: 3840)) == CGSize(width: 608, height: 1080))
        #expect(ProxyGenerator.proxySize(for: CGSize(width: 1280, height: 720)) == CGSize(width: 1280, height: 720))
    }

    @Test func proxyKeepsFramesTimingColorAndLeavesTheSourceUntouched() async throws {
        let temp = try TempDirectory()
        let source = try await writeTestMovie(to: temp.url.appendingPathComponent("P1.MOV"), frames: 48)
        let sourceBytes = try Data(contentsOf: source)
        let destination = temp.url.appendingPathComponent("proxy.mov")

        let info = try await ProxyGenerator.generate(
            source: source, destination: destination, maximumSize: CGSize(width: 320, height: 180)
        )

        #expect(info.frameCount == 48)
        #expect(info.pixelWidth == 320 && info.pixelHeight == 180)
        #expect(try Data(contentsOf: source) == sourceBytes, "The original must never change")
        #expect(!FileManager.default.fileExists(atPath: temp.url.appendingPathComponent("proxy.partial.mov").path))

        let sourceTrack = try await AVURLAsset(url: source).loadTracks(withMediaType: .video)[0]
        let proxyTrack = try await AVURLAsset(url: destination).loadTracks(withMediaType: .video)[0]
        let sourceRange = try await sourceTrack.load(.timeRange)
        let proxyRange = try await proxyTrack.load(.timeRange)
        #expect(proxyRange.start == sourceRange.start)
        #expect(abs(proxyRange.duration.seconds - sourceRange.duration.seconds) < 1.0 / 24)

        let proxyFormat = try await proxyTrack.load(.formatDescriptions)[0]
        #expect(CMFormatDescriptionGetMediaSubType(proxyFormat) == kCMVideoCodecType_AppleProRes422Proxy)
        #expect(CMFormatDescriptionGetExtension(proxyFormat, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String
            == (kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String))
        #expect(CMFormatDescriptionGetExtension(proxyFormat, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
            == (kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String))
    }

    @Test func cancellationLeavesNoFiles() async throws {
        let temp = try TempDirectory()
        let source = try await writeTestMovie(to: temp.url.appendingPathComponent("P1.MOV"), frames: 240, width: 1920, height: 1080)
        let destination = temp.url.appendingPathComponent("proxy.mov")
        let job = Task { try await ProxyGenerator.generate(source: source, destination: destination) }
        try await Task.sleep(for: .milliseconds(30))
        job.cancel()
        await #expect(throws: CancellationError.self) { _ = try await job.value }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: temp.url.path).filter { $0.hasPrefix("proxy") }
        #expect(leftovers.isEmpty)
    }

    @Test func fileWithoutVideoIsRejected() async throws {
        let temp = try TempDirectory()
        let junk = try temp.file("notes.mov", bytes: 4096, seed: 3)
        await #expect(throws: (any Error).self) {
            _ = try await ProxyGenerator.generate(source: junk, destination: temp.url.appendingPathComponent("proxy.mov"))
        }
        #expect(!FileManager.default.fileExists(atPath: temp.url.appendingPathComponent("proxy.mov").path))
    }
}
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `./scripts/test.sh --filter ProxyGeneratorTests`
Expected: compile failure, `cannot find 'ProxyGenerator' in scope`.

- [ ] **Step 3: Implement the generator**

```swift
// Sources/PerceptionEditor/ProxyGenerator.swift
@preconcurrency import AVFoundation
import Foundation

struct ProxyInfo: Equatable, Sendable {
    var url: URL
    var frameCount: Int
    var pixelWidth: Int
    var pixelHeight: Int
}

enum ProxyError: LocalizedError, Equatable {
    case noVideoTrack
    case readFailed(String)
    case writeFailed(String)
    case validationFailed(String)
    case insufficientSpace(neededBytes: Int64, availableBytes: Int64)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: "The file has no video track."
        case .readFailed(let reason): "The original could not be read: \(reason)"
        case .writeFailed(let reason): "The proxy could not be written: \(reason)"
        case .validationFailed(let reason): "The proxy did not match the original: \(reason)"
        case .insufficientSpace(let needed, let available):
            "Not enough free space for a proxy (needs \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)), \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) free)."
        }
    }
}

/// Transcodes one original into a ProRes 422 Proxy for editing. Frames are read as 10-bit 4:2:2;
/// asking the decoder for BGRA cut throughput to a quarter on the target M1 (12 fps vs 45 fps).
enum ProxyGenerator {
    static let defaultMaximumSize = CGSize(width: 1920, height: 1080)
    /// Measured on Lumix S5 UHD 23.976 footage: 44 MB per 10 s of 1080p ProRes 422 Proxy.
    static let bytesPerSecondAt1080p: Double = 4_500_000

    static func proxySize(for source: CGSize, maximum: CGSize = defaultMaximumSize) -> CGSize {
        guard source.width > 0, source.height > 0 else { return maximum }
        let scale = min(1, maximum.width / source.width, maximum.height / source.height)
        func even(_ value: CGFloat) -> CGFloat { max(2, (value * scale / 2).rounded(.down) * 2) }
        return CGSize(width: even(source.width), height: even(source.height))
    }

    static func estimatedBytes(durationSeconds: Double, proxySize: CGSize) -> Int64 {
        let pixelRatio = (proxySize.width * proxySize.height) / (1920 * 1080)
        return Int64(max(0, durationSeconds) * bytesPerSecondAt1080p * Double(pixelRatio))
    }

    static func generate(
        source: URL,
        destination: URL,
        maximumSize: CGSize = defaultMaximumSize,
        progress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> ProxyInfo {
        let fileManager = FileManager.default
        let partial = destination.deletingPathExtension().appendingPathExtension("partial.mov")
        try? fileManager.removeItem(at: partial)
        defer { try? fileManager.removeItem(at: partial) } // Already moved on success.

        let asset = AVURLAsset(url: source)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { throw ProxyError.noVideoTrack }
        let (naturalSize, transform, timeRange, formats) = try await track.load(
            .naturalSize, .preferredTransform, .timeRange, .formatDescriptions
        )
        let size = proxySize(for: naturalSize, maximum: maximumSize)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)

        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: partial, fileType: .mov) } catch {
            throw ProxyError.writeFailed(error.localizedDescription)
        }
        var settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.proRes422Proxy,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect
        ]
        if let format = formats.first, let colors = colorProperties(format) {
            settings[AVVideoColorPropertiesKey] = colors
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.transform = transform
        input.expectsMediaDataInRealTime = false
        writer.add(input)

        guard reader.startReading() else {
            throw ProxyError.readFailed(reader.error?.localizedDescription ?? "unknown error")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw ProxyError.writeFailed(writer.error?.localizedDescription ?? "unknown error")
        }
        writer.startSession(atSourceTime: timeRange.start)

        var written = 0
        let total = max(timeRange.duration.seconds, 0.001)
        do {
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
                guard input.append(sample) else {
                    throw ProxyError.writeFailed(writer.error?.localizedDescription ?? "append failed")
                }
                written += 1
                progress(min(1, (sample.presentationTimeStamp - timeRange.start).seconds / total))
            }
            try Task.checkCancellation()
            if reader.status == .failed {
                throw ProxyError.readFailed(reader.error?.localizedDescription ?? "unknown error")
            }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw ProxyError.writeFailed(writer.error?.localizedDescription ?? "finish failed")
        }

        let proxyFrames = try await frameCount(at: partial)
        guard proxyFrames == written, written > 0 else {
            throw ProxyError.validationFailed("\(proxyFrames) proxy frames, \(written) source frames")
        }
        let proxyTrack = try await AVURLAsset(url: partial).loadTracks(withMediaType: .video)[0]
        let proxyRange = try await proxyTrack.load(.timeRange)
        let frameSeconds = 1.0 / Double(max(1, try await track.load(.nominalFrameRate)))
        guard abs(proxyRange.duration.seconds - timeRange.duration.seconds) <= frameSeconds + 0.0005 else {
            throw ProxyError.validationFailed("duration \(proxyRange.duration.seconds)s vs \(timeRange.duration.seconds)s")
        }

        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.moveItem(at: partial, to: destination)
        progress(1)
        return ProxyInfo(url: destination, frameCount: written, pixelWidth: Int(size.width), pixelHeight: Int(size.height))
    }

    /// Counts frames without decoding them.
    static func frameCount(at url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ProxyError.noVideoTrack }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { throw ProxyError.readFailed(reader.error?.localizedDescription ?? "unknown") }
        var count = 0
        while let sample = output.copyNextSampleBuffer() { count += CMSampleBufferGetNumSamples(sample) }
        guard reader.status == .completed else { throw ProxyError.readFailed(reader.error?.localizedDescription ?? "unknown") }
        return count
    }

    /// AVFoundation requires all three color keys together. A source missing any of them stays untagged.
    private static func colorProperties(_ format: CMFormatDescription) -> [String: String]? {
        func value(_ key: CFString) -> String? { CMFormatDescriptionGetExtension(format, extensionKey: key) as? String }
        guard let primaries = value(kCMFormatDescriptionExtension_ColorPrimaries),
              let transfer = value(kCMFormatDescriptionExtension_TransferFunction),
              let matrix = value(kCMFormatDescriptionExtension_YCbCrMatrix) else { return nil }
        return [
            AVVideoColorPrimariesKey: primaries,
            AVVideoTransferFunctionKey: transfer,
            AVVideoYCbCrMatrixKey: matrix
        ]
    }
}
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `./scripts/test.sh --filter "ProxyGeneratorTests|ProxyFingerprintTests"`
Expected: all pass. If `cancellationLeavesNoFiles` finishes before the cancel lands (the encode is too fast), raise `frames` to 480 rather than shortening the sleep.

- [ ] **Step 5: Commit**

```bash
git add Sources/PerceptionEditor/ProxyGenerator.swift Tests/PerceptionEditorTests/ProxyGeneratorTests.swift
git commit -m "Generate validated ProRes 422 Proxy files from 10-bit 4:2:2 originals"
```

---

### Task 3: Real-footage gate (opt-in)

**Files:**
- Create: `Tests/PerceptionEditorTests/RealVideoProxyTests.swift`

**Interfaces:**
- Consumes: `ProxyGenerator.generate`, `ProxyGenerator.frameCount`

- [ ] **Step 1: Write the opt-in test**

```swift
// Tests/PerceptionEditorTests/RealVideoProxyTests.swift
@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import PerceptionEditor

/// Run with PME_VIDEO_SAMPLE=/Volumes/ExSSD1/Pictures/110_PANA/P1107157.MOV on the target M1.
struct RealVideoProxyTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PME_VIDEO_SAMPLE"] != nil))
    func lumixProxyIsFasterThanRealtimeAndFrameExact() async throws {
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PME_VIDEO_SAMPLE"]!)
        let temp = try TempDirectory()
        let trimmed = temp.url.appendingPathComponent("sample.mov")
        // Ten seconds keeps the gate short; copy by passthrough export, never touch the original.
        let export = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetPassthrough)!
        export.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 10, preferredTimescale: 24000))
        try await export.export(to: trimmed, as: .mov)

        let clock = ContinuousClock()
        let start = clock.now
        let info = try await ProxyGenerator.generate(source: trimmed, destination: temp.url.appendingPathComponent("proxy.mov"))
        let elapsed = (clock.now - start).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        let fps = Double(info.frameCount) / seconds
        print("Proxy: \(info.frameCount) frames, \(String(format: "%.1f", fps)) fps, \(info.pixelWidth)x\(info.pixelHeight)")
        #expect(info.frameCount == (try await ProxyGenerator.frameCount(at: trimmed)))
        #expect(fps >= 28.8, "Generation must stay at or above 1.2x realtime for 23.976 fps footage")
    }
}
```

- [ ] **Step 2: Run it against real footage**

Run: `PME_VIDEO_SAMPLE=/Volumes/ExSSD1/Pictures/110_PANA/P1107157.MOV ./scripts/test.sh --filter RealVideoProxyTests`
Expected: PASS, printing about 40 fps at 1920×1080. Record the number in the Verification table below.

- [ ] **Step 3: Commit**

```bash
git add Tests/PerceptionEditorTests/RealVideoProxyTests.swift
git commit -m "Add opt-in real Lumix footage gate for proxy generation"
```

---

### Task 4: Composition resolves proxies for preview and originals for export

**Files:**
- Modify: `Sources/PerceptionEditor/TimelineCompositionService.swift` (struct at top; `makePlayerItem` signature and clip loop; video-composition block)
- Test: `Tests/PerceptionEditorTests/TimelineProxyCompositionTests.swift`

**Interfaces:**
- Consumes: `ProxyGenerator.generate`, `writeTestMovie`
- Produces:
  - `enum MediaQuality: Sendable { case preview, export }`
  - `struct ClipSourceURLs: Equatable, Sendable { var video: URL; var audio: URL; var usesProxy: Bool }`
  - `nonisolated static func TimelineCompositionService.sourceURLs(for: MediaAsset, quality: MediaQuality, proxyURL: URL?) -> ClipSourceURLs`
  - `TimelineCompositionResult.usedProxyCount: Int`
  - `makePlayerItem(clips:media:adjustmentsByClipID:audioAdjustmentsByClipID:quality: MediaQuality = .preview, proxyURLsByAssetID: [UUID: URL] = [:])`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/PerceptionEditorTests/TimelineProxyCompositionTests.swift
@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import PerceptionEditor

@MainActor
struct TimelineProxyCompositionTests {
    private func fixture(_ temp: TempDirectory, _ name: String) async throws -> (MediaAsset, URL) {
        let original = try await writeTestMovie(to: temp.url.appendingPathComponent("\(name).MOV"), frames: 48)
        let proxy = try await ProxyGenerator.generate(
            source: original,
            destination: temp.url.appendingPathComponent("\(name)-proxy.mov"),
            maximumSize: CGSize(width: 320, height: 180)
        ).url
        return (MediaAsset(url: original, kind: .video, durationSeconds: 48 * 1001 / 24000.0), proxy)
    }

    private func videoSourceURLs(_ item: AVPlayerItem?) -> [URL] {
        let composition = item?.asset as? AVComposition
        let track = composition?.tracks(withMediaType: .video).first
        return track?.segments.compactMap { $0.isEmpty ? nil : $0.sourceURL } ?? []
    }

    @Test func sourceResolutionRules() {
        let asset = MediaAsset(url: URL(fileURLWithPath: "/clips/A.MOV"), kind: .video)
        let proxy = URL(fileURLWithPath: "/cache/a.mov")
        #expect(TimelineCompositionService.sourceURLs(for: asset, quality: .preview, proxyURL: proxy)
            == ClipSourceURLs(video: proxy, audio: asset.url, usesProxy: true))
        #expect(TimelineCompositionService.sourceURLs(for: asset, quality: .export, proxyURL: proxy)
            == ClipSourceURLs(video: asset.url, audio: asset.url, usesProxy: false))
        #expect(TimelineCompositionService.sourceURLs(for: asset, quality: .preview, proxyURL: nil)
            == ClipSourceURLs(video: asset.url, audio: asset.url, usesProxy: false))
    }

    @Test func previewPlaysProxyAndExportUsesOriginal() async throws {
        let temp = try TempDirectory()
        let (asset, proxy) = try await fixture(temp, "A")
        let clip = TimelineClip(assetID: asset.id, durationSeconds: 1.0)
        let service = TimelineCompositionService.shared

        let preview = await service.makePlayerItem(clips: [clip], media: [asset], proxyURLsByAssetID: [asset.id: proxy])
        #expect(videoSourceURLs(preview.playerItem) == [proxy])
        #expect(preview.usedProxyCount == 1)

        let export = await service.makePlayerItem(
            clips: [clip], media: [asset], quality: .export, proxyURLsByAssetID: [asset.id: proxy]
        )
        #expect(videoSourceURLs(export.playerItem) == [asset.url])
        #expect(export.usedProxyCount == 0)
    }

    @Test func missingProxyFileFallsBackToOriginal() async throws {
        let temp = try TempDirectory()
        let (asset, proxy) = try await fixture(temp, "A")
        try FileManager.default.removeItem(at: proxy)
        let result = await TimelineCompositionService.shared.makePlayerItem(
            clips: [TimelineClip(assetID: asset.id, durationSeconds: 1.0)],
            media: [asset],
            proxyURLsByAssetID: [asset.id: proxy]
        )
        #expect(videoSourceURLs(result.playerItem) == [asset.url])
        #expect(result.warnings.isEmpty)
    }

    @Test func mixedTimelineRendersAtProxySize() async throws {
        let temp = try TempDirectory()
        let (a, proxyA) = try await fixture(temp, "A")
        let b = MediaAsset(
            url: try await writeTestMovie(to: temp.url.appendingPathComponent("B.MOV"), frames: 48),
            kind: .video
        )
        let clips = [
            TimelineClip(assetID: a.id, timelineStartSeconds: 0, durationSeconds: 1.0),
            TimelineClip(assetID: b.id, timelineStartSeconds: 1.0, durationSeconds: 1.0)
        ]
        let result = await TimelineCompositionService.shared.makePlayerItem(
            clips: clips, media: [a, b], proxyURLsByAssetID: [a.id: proxyA]
        )
        let item = try #require(result.playerItem)
        let videoComposition = try #require(item.videoComposition)
        #expect(videoComposition.renderSize == CGSize(width: 320, height: 180))

        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.videoComposition = videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let frame = try await generator.image(at: CMTime(seconds: 1.5, preferredTimescale: 24000)).image
        #expect(frame.width == 320 && frame.height == 180, "The unproxied clip is scaled into the proxy frame")
    }
}
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `./scripts/test.sh --filter TimelineProxyCompositionTests`
Expected: compile failure on `ClipSourceURLs`, `quality:`, `proxyURLsByAssetID:`, `usedProxyCount`.

- [ ] **Step 3: Add the types and resolution rule** (top of `TimelineCompositionService.swift`)

```swift
enum MediaQuality: Sendable {
    /// Editing playback. Uses a ready proxy when one exists.
    case preview
    /// Deliverables. Always reads camera originals.
    case export
}

struct ClipSourceURLs: Equatable, Sendable {
    var video: URL
    var audio: URL
    var usesProxy: Bool
}
```

Add `var usedProxyCount = 0` as the last stored property of `TimelineCompositionResult`, and pass `usedProxyCount:` at each of the three construction sites (`0` for the two early returns).

Inside `TimelineCompositionService`:

```swift
    /// Proxies are video-only, so audio always comes from the original. A proxy URL whose file
    /// has gone (the cache was cleared) falls back to the original without a warning.
    nonisolated static func sourceURLs(for asset: MediaAsset, quality: MediaQuality, proxyURL: URL?) -> ClipSourceURLs {
        guard quality == .preview, let proxyURL else {
            return ClipSourceURLs(video: asset.url, audio: asset.url, usesProxy: false)
        }
        return ClipSourceURLs(video: proxyURL, audio: asset.url, usesProxy: true)
    }
```

- [ ] **Step 4: Use it in `makePlayerItem`**

Change the signature:

```swift
    func makePlayerItem(
        clips: [TimelineClip],
        media: [MediaAsset],
        adjustmentsByClipID: [UUID: PhotoAdjustments] = [:],
        audioAdjustmentsByClipID: [UUID: ClipAudioAdjustments] = [:],
        quality: MediaQuality = .preview,
        proxyURLsByAssetID: [UUID: URL] = [:]
    ) async -> TimelineCompositionResult {
```

Add `var usedProxyCount = 0` and `var proxyRenderSize: CGSize?` next to `didSetVideoTransform`. In the clip loop, replace `let sourceAsset = AVURLAsset(url: mediaAsset.url)` and the video-track lookup with:

```swift
            let proxyURL = proxyURLsByAssetID[clip.assetID]
                .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            let sources = Self.sourceURLs(for: mediaAsset, quality: quality, proxyURL: proxyURL)
            let sourceAsset = AVURLAsset(url: sources.video)
            let audioAsset = sources.audio == sources.video ? sourceAsset : AVURLAsset(url: sources.audio)
```

Keep the existing duration and video-track guards (now reading `sourceAsset`, which may be the proxy). After a successful `compositionVideoTrack.insertTimeRange`:

```swift
            if sources.usesProxy {
                usedProxyCount += 1
                if proxyRenderSize == nil, let size = try? await sourceVideoTrack.load(.naturalSize) {
                    proxyRenderSize = size
                }
            }
```

In the audio branch, replace `sourceAsset.loadTracks(withMediaType: .audio)` with `audioAsset.loadTracks(withMediaType: .audio)`.

- [ ] **Step 5: Build the video composition when a proxy is in use and scale frames to fit**

Replace the condition `if colorSegments.contains(where: { $0.adjustments != .neutral }) {` with:

```swift
        let needsColor = colorSegments.contains(where: { $0.adjustments != .neutral })
        if needsColor || proxyRenderSize != nil {
            let renderSize = proxyRenderSize
```

Inside the handler, before `MediaColorRenderer.render`, fit the frame to the render size:

```swift
                        var source = request.sourceImage
                        if let renderSize, source.extent.size != renderSize {
                            let scale = min(renderSize.width / source.extent.width, renderSize.height / source.extent.height)
                            source = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                            let dx = (renderSize.width - source.extent.width) / 2 - source.extent.minX
                            let dy = (renderSize.height - source.extent.height) / 2 - source.extent.minY
                            source = source.transformed(by: CGAffineTransform(translationX: dx, y: dy))
                                .composited(over: CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: renderSize)))
                        }
                        let output = MediaColorRenderer.render(source, adjustments: adjustments, includesGeometry: false)
                        request.finish(with: output.cropped(to: CGRect(origin: .zero, size: renderSize ?? request.sourceImage.extent.size)), context: nil)
```

After the completion handler returns `videoComposition`, apply the size:

```swift
            if let videoComposition = videoCompositionResult.value {
                if let renderSize, let mutable = videoComposition.mutableCopy() as? AVMutableVideoComposition {
                    mutable.renderSize = renderSize
                    playerItem.videoComposition = mutable
                } else {
                    playerItem.videoComposition = videoComposition
                }
            } else {
                warnings.append("Clip color could not be previewed.")
            }
```

Return `usedProxyCount: usedProxyCount` in the final result.

- [ ] **Step 6: Run the tests and confirm they pass**

Run: `./scripts/test.sh --filter TimelineProxyCompositionTests`
Expected: 4 tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/PerceptionEditor/TimelineCompositionService.swift Tests/PerceptionEditorTests/TimelineProxyCompositionTests.swift
git commit -m "Play timeline from proxies in preview and resolve originals for export"
```

---

### Task 5: ProxyStore — queue, reuse, disk guard, cancel

**Files:**
- Create: `Sources/PerceptionEditor/ProxyStore.swift`
- Modify: `Tests/PerceptionEditorTests/VideoTestSupport.swift` (add `waitForProxy` from Task 1 Step 1)
- Test: `Tests/PerceptionEditorTests/ProxyStoreTests.swift`

**Interfaces:**
- Consumes: `ProxyFingerprint.key`, `ProxyGenerator.generate/proxySize/estimatedBytes`, `ProxyError`
- Produces:
  - `enum ProxyStatus: Equatable, Sendable { case missing, queued, generating(Double), ready(URL), failed(String) }`
  - `@MainActor final class ProxyStore: ObservableObject` with:
    - `init(directory: URL = ProxyStore.defaultDirectory(), maximumSize: CGSize = ProxyGenerator.defaultMaximumSize, availableBytes: @escaping @Sendable (URL) -> Int64? = ProxyStore.availableBytes)`
    - `@Published private(set) var statuses: [UUID: ProxyStatus]`
    - `var onReady: ((UUID) -> Void)?`
    - `var readyURLs: [UUID: URL]`
    - `func readyURL(for: UUID) -> URL?`
    - `func enqueue(_ assets: [MediaAsset], prioritized: Set<UUID> = [])`
    - `func invalidate(assetID: UUID)`
    - `func cancelAll()`
    - `func removeAllProxies() throws`
    - `nonisolated static func defaultDirectory() -> URL`
    - `nonisolated static func availableBytes(_ url: URL) -> Int64?`
    - `nonisolated static let reserveBytes: Int64` (2 GiB)

- [ ] **Step 1: Add the wait helper, then write the failing tests**

Append to `Tests/PerceptionEditorTests/VideoTestSupport.swift`:

```swift
/// Polls until the asset's proxy is ready or failed.
@MainActor
func waitForProxy(_ store: ProxyStore, _ id: UUID, timeout: Duration = .seconds(60)) async throws -> ProxyStatus {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        switch store.statuses[id] {
        case .ready?, .failed?: return store.statuses[id]!
        default: try await Task.sleep(for: .milliseconds(20))
        }
    }
    Issue.record("Proxy for \(id) did not finish within \(timeout)")
    return store.statuses[id] ?? .missing
}
```


```swift
// Tests/PerceptionEditorTests/ProxyStoreTests.swift
import Foundation
import Testing
@testable import PerceptionEditor

@MainActor
struct ProxyStoreTests {
    private func makeStore(_ temp: TempDirectory, free: Int64? = 1 << 40) throws -> ProxyStore {
        ProxyStore(
            directory: try temp.subdirectory("Proxy Cache"),
            maximumSize: CGSize(width: 320, height: 180),
            availableBytes: { _ in free }
        )
    }

    private func video(_ temp: TempDirectory, _ name: String) async throws -> MediaAsset {
        let url = try await writeTestMovie(to: temp.url.appendingPathComponent(name), frames: 24)
        return MediaAsset(url: url, kind: .video, durationSeconds: 1.0)
    }

    @Test func enqueuedVideoBecomesReadyAndNotifies() async throws {
        let temp = try TempDirectory()
        let store = try makeStore(temp)
        let asset = try await video(temp, "A.MOV")
        var notified: [UUID] = []
        store.onReady = { notified.append($0) }
        store.enqueue([asset, MediaAsset(url: temp.url.appendingPathComponent("p.jpg"), kind: .photo)])
        guard case .ready(let url) = try await waitForProxy(store, asset.id) else { Issue.record("not ready"); return }
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(store.readyURL(for: asset.id) == url)
        #expect(notified == [asset.id])
        #expect(store.statuses.count == 1, "Photos never get proxies")
    }

    @Test func movedSourceReusesProxy() async throws {
        let temp = try TempDirectory()
        let store = try makeStore(temp)
        var asset = try await video(temp, "A.MOV")
        store.enqueue([asset])
        guard case .ready(let first) = try await waitForProxy(store, asset.id) else { return }
        let stamp = try FileManager.default.attributesOfItem(atPath: first.path)[.modificationDate] as? Date

        let moved = temp.url.appendingPathComponent("moved/A.MOV")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: asset.url, to: moved)
        asset.url = moved
        store.invalidate(assetID: asset.id)
        store.enqueue([asset])
        guard case .ready(let second) = try await waitForProxy(store, asset.id) else { return }
        #expect(second == first)
        #expect(try FileManager.default.attributesOfItem(atPath: second.path)[.modificationDate] as? Date == stamp)
    }

    @Test func deletedProxyIsRegenerated() async throws {
        let temp = try TempDirectory()
        let store = try makeStore(temp)
        let asset = try await video(temp, "A.MOV")
        store.enqueue([asset])
        guard case .ready(let url) = try await waitForProxy(store, asset.id) else { return }
        try FileManager.default.removeItem(at: url)
        store.invalidate(assetID: asset.id)
        store.enqueue([asset])
        guard case .ready = try await waitForProxy(store, asset.id) else { Issue.record("not regenerated"); return }
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func insufficientSpaceFailsWithoutWriting() async throws {
        let temp = try TempDirectory()
        let store = try makeStore(temp, free: 1_000_000)
        let asset = try await video(temp, "A.MOV")
        store.enqueue([asset])
        guard case .failed(let message) = try await waitForProxy(store, asset.id) else { Issue.record("should fail"); return }
        #expect(message.contains("Not enough free space"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).isEmpty)
    }

    @Test func prioritizedAssetsRunFirstAndCancelAllStopsTheQueue() async throws {
        let temp = try TempDirectory()
        let store = try makeStore(temp)
        let a = try await video(temp, "A.MOV")
        let b = try await video(temp, "B.MOV")
        var order: [UUID] = []
        store.onReady = { order.append($0) }
        store.enqueue([a, b], prioritized: [b.id])
        guard case .ready = try await waitForProxy(store, b.id) else { return }
        #expect(order.first == b.id, "Timeline clips are generated before the rest of the library")
        store.cancelAll()
        #expect(store.statuses[a.id] != .queued)
        if case .generating = store.statuses[a.id] { Issue.record("cancelAll must stop the running job") }
        try await Task.sleep(for: .milliseconds(200))
        let partials = try FileManager.default.contentsOfDirectory(atPath: store.directory.path).filter { $0.hasSuffix(".partial.mov") }
        #expect(partials.isEmpty)
    }

    @Test func unreadableVideoFailsWithReason() async throws {
        let temp = try TempDirectory()
        let store = try makeStore(temp)
        let junk = MediaAsset(url: try temp.file("bad.MOV", bytes: 4096, seed: 9), kind: .video, durationSeconds: 1)
        store.enqueue([junk])
        guard case .failed = try await waitForProxy(store, junk.id) else { Issue.record("should fail"); return }
    }
}
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `./scripts/test.sh --filter ProxyStoreTests`
Expected: compile failure, `cannot find 'ProxyStore' in scope`.

- [ ] **Step 3: Implement the store**

```swift
// Sources/PerceptionEditor/ProxyStore.swift
import Foundation

enum ProxyStatus: Equatable, Sendable {
    case missing
    case queued
    case generating(Double)
    case ready(URL)
    case failed(String)
}

/// Owns proxy status and runs one generation at a time. Proxies are a disposable cache keyed by
/// source content; deleting the directory never loses edits, it only costs regeneration time.
@MainActor
final class ProxyStore: ObservableObject {
    nonisolated static let directoryDefaultsKey = "perceptionEditor.proxyDirectory"
    nonisolated static let reserveBytes: Int64 = 2 * 1_024 * 1_024 * 1_024

    @Published private(set) var statuses: [UUID: ProxyStatus] = [:]
    var onReady: ((UUID) -> Void)?

    let directory: URL
    private let maximumSize: CGSize
    private let availableBytes: @Sendable (URL) -> Int64?
    private var queue: [MediaAsset] = []
    private var worker: Task<Void, Never>?
    /// A cancelled worker may still be unwinding when a new one starts; only the current one clears `worker`.
    private var workerToken = UUID()

    init(
        directory: URL = ProxyStore.defaultDirectory(),
        maximumSize: CGSize = ProxyGenerator.defaultMaximumSize,
        availableBytes: @escaping @Sendable (URL) -> Int64? = ProxyStore.availableBytes
    ) {
        self.directory = directory
        self.maximumSize = maximumSize
        self.availableBytes = availableBytes
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    nonisolated static func defaultDirectory() -> URL {
        if let path = UserDefaults.standard.string(forKey: directoryDefaultsKey) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("Perception Media Editor", isDirectory: true)
            .appendingPathComponent("Proxy Cache", isDirectory: true)
    }

    nonisolated static func availableBytes(_ url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    var readyURLs: [UUID: URL] {
        statuses.compactMapValues { status -> URL? in
            guard case .ready(let url) = status else { return nil }
            return url
        }
    }

    func readyURL(for assetID: UUID) -> URL? {
        if case .ready(let url) = statuses[assetID] { url } else { nil }
    }

    func enqueue(_ assets: [MediaAsset], prioritized: Set<UUID> = []) {
        let pending = Set(queue.map(\.id))
        let fresh = assets.filter { asset in
            guard asset.kind == .video, !pending.contains(asset.id) else { return false }
            switch statuses[asset.id] {
            case .queued?, .generating?, .ready?: return false
            default: return true
            }
        }
        for asset in fresh { statuses[asset.id] = .queued }
        queue.append(contentsOf: fresh)
        queue.sort { prioritized.contains($0.id) && !prioritized.contains($1.id) }
        startWorkerIfNeeded()
    }

    /// Forget an asset's status after relink or when its proxy file disappeared.
    func invalidate(assetID: UUID) {
        queue.removeAll { $0.id == assetID }
        statuses[assetID] = nil
    }

    func cancelAll() {
        worker?.cancel()
        worker = nil
        for asset in queue { statuses[asset.id] = .missing }
        queue = []
        for (id, status) in statuses { if case .generating = status { statuses[id] = .missing } }
    }

    func removeAllProxies() throws {
        cancelAll()
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for url in contents where url.pathExtension == "mov" { try FileManager.default.removeItem(at: url) }
        statuses = [:]
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, !queue.isEmpty else { return }
        let token = UUID()
        workerToken = token
        worker = Task { [weak self] in
            while let self, !Task.isCancelled, !self.queue.isEmpty {
                let asset = self.queue.removeFirst()
                await self.process(asset)
            }
            if let self, self.workerToken == token { self.worker = nil }
        }
    }

    private func process(_ asset: MediaAsset) async {
        let directory = directory
        let maximumSize = maximumSize
        let availableBytes = availableBytes
        let assetID = asset.id
        statuses[assetID] = .generating(0)

        let job = Task.detached(priority: .utility) { () throws -> URL in
            let key = try ProxyFingerprint.key(for: asset.url)
            let destination = directory.appendingPathComponent(key).appendingPathExtension("mov")
            if FileManager.default.fileExists(atPath: destination.path) { return destination }

            let size = ProxyGenerator.proxySize(
                for: CGSize(width: asset.pixelWidth ?? 3840, height: asset.pixelHeight ?? 2160), maximum: maximumSize
            )
            let needed = ProxyGenerator.estimatedBytes(durationSeconds: asset.durationSeconds ?? 0, proxySize: size)
                + ProxyStore.reserveBytes
            if let available = availableBytes(directory), available < needed {
                throw ProxyError.insufficientSpace(neededBytes: needed, availableBytes: available)
            }
            return try await ProxyGenerator.generate(source: asset.url, destination: destination, maximumSize: maximumSize) { fraction in
                Task { @MainActor [weak self] in
                    guard let self, case .generating = self.statuses[assetID] else { return }
                    self.statuses[assetID] = .generating(fraction)
                }
            }.url
        }

        let outcome = await withTaskCancellationHandler {
            await job.result
        } onCancel: {
            job.cancel()
        }
        guard !Task.isCancelled else { return }
        switch outcome {
        case .success(let url):
            statuses[assetID] = .ready(url)
            onReady?(assetID)
        case .failure(let error as ProxyError):
            statuses[assetID] = .failed(error.errorDescription ?? "Proxy failed")
        case .failure(is CancellationError):
            statuses[assetID] = .missing
        case .failure(let error):
            statuses[assetID] = .failed(error.localizedDescription)
        }
    }
}
```

Note: `ProxyGenerator.generate`'s `progress` parameter is non-escaping `@Sendable`. The closure above captures `self` weakly through a `Task`, which is allowed. If Swift 6 strict concurrency rejects `[weak self]` inside a detached task, capture a `@MainActor` reporting closure built before `Task.detached` instead:

```swift
let report: @Sendable (Double) -> Void = { [weak self] fraction in
    Task { @MainActor in
        guard let self, case .generating = self.statuses[assetID] else { return }
        self.statuses[assetID] = .generating(fraction)
    }
}
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `./scripts/test.sh --filter "ProxyStoreTests|ProxyGeneratorTests|TimelineProxyCompositionTests"`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/PerceptionEditor/ProxyStore.swift Tests/PerceptionEditorTests/ProxyStoreTests.swift Tests/PerceptionEditorTests/VideoTestSupport.swift
git commit -m "Queue proxy generation with content-keyed reuse and a disk-space guard"
```

---

### Task 6: Wire proxies into EditorStore (import, ingest, open, relink, playback)

**Files:**
- Modify: `Sources/PerceptionEditor/EditorStore.swift` (init around line 159, `importURLsAsync` around line 300, `resetToEmptyProject` around line 751, `loadProject` around line 819–850, relink around line 1099, `showSourceVideo` line 1328, `rebuildTimelinePlayback` line 1349)
- Modify: `Sources/PerceptionEditor/EditorStore+Ingest.swift` (video metadata task around line 279)
- Test: `Tests/PerceptionEditorTests/VideoProxyWorkflowTests.swift`

**Interfaces:**
- Consumes: `ProxyStore` (Task 5), `makePlayerItem(... proxyURLsByAssetID:)` (Task 4)
- Produces:
  - `EditorStore.init(..., proxyStore: ProxyStore = ProxyStore(), proxyDefaults: UserDefaults = .standard)`. Tests pass a throwaway suite so they never change the real app's setting.
  - `let proxyStore: ProxyStore`
  - `@Published var usesProxiesForPlayback: Bool` (key `perceptionEditor.useProxies` in `proxyDefaults`, default `true`)
  - `@Published var timelineUsedProxyCount: Int`

- [ ] **Step 1: Write the failing workflow tests**

```swift
// Tests/PerceptionEditorTests/VideoProxyWorkflowTests.swift
@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import PerceptionEditor

@MainActor
struct VideoProxyWorkflowTests {
    private func makeStore(_ temp: TempDirectory) throws -> EditorStore {
        let suite = "pme-proxy-tests-\(UUID().uuidString)"
        return EditorStore(
            presetRepository: UserPresetRepository(defaults: UserDefaults(suiteName: suite)!),
            proxyStore: ProxyStore(
                directory: try temp.subdirectory("Proxy Cache"),
                maximumSize: CGSize(width: 320, height: 180),
                availableBytes: { _ in 1 << 40 }
            ),
            proxyDefaults: UserDefaults(suiteName: suite)!
        )
    }

    @Test func importedVideoGetsAProxyAndTheTimelinePlaysIt() async throws {
        let temp = try TempDirectory()
        let store = try makeStore(temp)
        let movie = try await writeTestMovie(to: temp.url.appendingPathComponent("A.MOV"), frames: 48)
        await store.importURLs([movie]).value
        let asset = try #require(store.project.media.first)
        guard case .ready(let proxy) = try await waitForProxy(store.proxyStore, asset.id) else { return }

        store.addToTimeline(asset)
        try await waitUntil { store.timelineUsedProxyCount == 1 }
        let composition = try #require(store.videoPlayer?.currentItem?.asset as? AVComposition)
        #expect(composition.tracks(withMediaType: .video).first?.segments.first?.sourceURL == proxy)
    }

    @Test func turningProxiesOffPlaysOriginals() async throws {
        let temp = try TempDirectory()
        let store = try makeStore(temp)
        let movie = try await writeTestMovie(to: temp.url.appendingPathComponent("A.MOV"), frames: 48)
        await store.importURLs([movie]).value
        let asset = try #require(store.project.media.first)
        _ = try await waitForProxy(store.proxyStore, asset.id)
        store.addToTimeline(asset)
        try await waitUntil { store.timelineUsedProxyCount == 1 }

        store.usesProxiesForPlayback = false
        try await waitUntil { store.timelineUsedProxyCount == 0 && store.videoPlayer?.currentItem != nil }
        let composition = try #require(store.videoPlayer?.currentItem?.asset as? AVComposition)
        #expect(composition.tracks(withMediaType: .video).first?.segments.first?.sourceURL == movie)
    }

    @Test func proxyReadyRebuildKeepsPosition() async throws {
        let temp = try TempDirectory()
        let store = try makeStore(temp)
        let movie = try await writeTestMovie(to: temp.url.appendingPathComponent("A.MOV"), frames: 96)
        await store.importURLs([movie]).value
        let asset = try #require(store.project.media.first)
        store.proxyStore.cancelAll() // Build the timeline from the original first.
        store.addToTimeline(asset)
        try await waitUntil { store.videoPlayer?.currentItem != nil }
        store.seekTimeline(to: 2.0)

        store.proxyStore.invalidate(assetID: asset.id)
        store.proxyStore.enqueue([asset])
        _ = try await waitForProxy(store.proxyStore, asset.id)
        try await waitUntil { store.timelineUsedProxyCount == 1 }
        #expect(abs(store.timelinePlaybackPositionSeconds - 2.0) < 0.1)
    }

    @Test func newProjectCancelsPendingProxies() async throws {
        let temp = try TempDirectory()
        let store = try makeStore(temp)
        let movie = try await writeTestMovie(to: temp.url.appendingPathComponent("A.MOV"), frames: 480, width: 1920, height: 1080)
        await store.importURLs([movie]).value
        store.resetToEmptyProject(named: "Next")
        #expect(!store.proxyStore.statuses.values.contains { if case .generating = $0 { true } else { $0 == .queued } })
    }
}

@MainActor
func waitUntil(timeout: Duration = .seconds(30), _ condition: () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        guard clock.now < deadline else { Issue.record("Condition not met within \(timeout)"); return }
        try await Task.sleep(for: .milliseconds(20))
    }
}
```

Before writing these, check the exact names of the existing timeline and seek entry points with `grep -n "func addToTimeline\|func seekTimeline\|var videoPlayer\|timelinePlaybackPositionSeconds" Sources/PerceptionEditor/EditorStore.swift`. If the add-clip action has a different name, use that name in the tests. Don't add a new API just for tests.

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `./scripts/test.sh --filter VideoProxyWorkflowTests`
Expected: compile failure on `proxyStore:`, `timelineUsedProxyCount`, `usesProxiesForPlayback`.

- [ ] **Step 3: Own the store and forward its changes**

In `EditorStore`, near the other published playback state:

```swift
    static let useProxiesKey = "perceptionEditor.useProxies"
    let proxyStore: ProxyStore
    private let proxyDefaults: UserDefaults
    @Published private(set) var timelineUsedProxyCount = 0
    @Published var usesProxiesForPlayback = true {
        didSet {
            proxyDefaults.set(usesProxiesForPlayback, forKey: Self.useProxiesKey)
            refreshPlaybackSources()
        }
    }
```

Add `proxyStore: ProxyStore = ProxyStore(), proxyDefaults: UserDefaults = .standard` as the last `init` parameters. Assign the stored properties at the top of the body (property observers don't fire in `init`):

```swift
        self.proxyStore = proxyStore
        self.proxyDefaults = proxyDefaults
        usesProxiesForPlayback = proxyDefaults.object(forKey: Self.useProxiesKey) as? Bool ?? true
```

At the end of the body, after the `$project` autosave sink:

```swift
        proxyStore.onReady = { [weak self] id in self?.proxyBecameReady(id) }
        proxyStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
```

- [ ] **Step 4: Enqueue at every point where video enters the project**

- `importURLsAsync`, in the `.video, .audio` branch right after `project.media.append(asset)`: `proxyStore.enqueue([asset])`. `enqueue` ignores `.audio`.
- `EditorStore+Ingest.swift`, inside the metadata `Task` after the three `project.media[index]` assignments: `proxyStore.enqueue([project.media[index]])`. Metadata must be filled in first so the disk estimate uses the real duration.
- `resetToEmptyProject(named:)`, after `projectGeneration = UUID()`: `proxyStore.cancelAll()`.
- `loadProject(from:)`, after `projectGeneration = UUID()`: `proxyStore.cancelAll()`. Then, after the waveform loop: `proxyStore.enqueue(project.media, prioritized: Set(project.timelineClips.map(\.assetID)))`.
- Relink: inside the video branch's `Task` after updating metadata, add `proxyStore.invalidate(assetID: target.id)` and then `proxyStore.enqueue([project.media[currentIndex]])`.

- [ ] **Step 5: Play from proxies**

```swift
    private func playbackURL(for asset: MediaAsset) -> URL {
        guard usesProxiesForPlayback, let proxy = proxyStore.readyURL(for: asset.id),
              FileManager.default.fileExists(atPath: proxy.path) else { return asset.url }
        return proxy
    }

    private func proxyBecameReady(_ assetID: UUID) {
        guard usesProxiesForPlayback else { return }
        if project.timelineClips.contains(where: { $0.assetID == assetID }) {
            rebuildTimelinePlayback() // Keeps position and play state.
        } else if !isTimelinePlayback, selectedVideoAssetID == assetID, !isVideoPlaying,
                  let asset = project.media.first(where: { $0.id == assetID }) {
            showSourceVideo(asset)
        }
    }

    private func refreshPlaybackSources() {
        if isTimelinePlayback {
            rebuildTimelinePlayback()
        } else if let asset = selectedVideoAsset {
            showSourceVideo(asset)
        }
    }
```

In `showSourceVideo`, change `AVPlayer(url: asset.url)` to `AVPlayer(url: playbackURL(for: asset))`.

In `rebuildTimelinePlayback`, capture `let proxyURLs = usesProxiesForPlayback ? proxyStore.readyURLs : [:]` next to the other captures. Pass `proxyURLsByAssetID: proxyURLs` to `makePlayerItem`, and after the warnings assignment set `timelineUsedProxyCount = result.usedProxyCount`. When the timeline is empty, also set `timelineUsedProxyCount = 0`.

- [ ] **Step 6: Run the tests and confirm they pass**

Run: `./scripts/test.sh --filter "VideoProxyWorkflowTests|ReliabilityTests|ProjectDocumentTests"`
Expected: all pass. `ProjectDocumentTests` must pass unchanged, which proves there is no schema change.

- [ ] **Step 7: Commit**

```bash
git add Sources/PerceptionEditor/EditorStore.swift Sources/PerceptionEditor/EditorStore+Ingest.swift Tests/PerceptionEditorTests/VideoProxyWorkflowTests.swift
git commit -m "Generate proxies on import, ingest, open, and relink; play timeline from proxies"
```

---

### Task 7: Proxy status in the video workspace

**Files:**
- Modify: `Sources/PerceptionEditor/VideoWorkspace.swift` (`videoCard` overlay, around lines 75–86; timeline toolbar)

**Interfaces:**
- Consumes: `store.proxyStore.statuses`, `store.usesProxiesForPlayback`, `store.timelineUsedProxyCount`

- [ ] **Step 1: Add the badge view** (bottom of `VideoWorkspace.swift`)

```swift
private struct ProxyBadge: View {
    let status: ProxyStatus?

    var body: some View {
        switch status {
        case .ready?:
            label("PROXY", systemImage: "bolt.fill", tint: .green)
        case .generating(let fraction)?:
            label("\(Int(fraction * 100))%", systemImage: "gearshape.2", tint: .orange)
        case .queued?:
            label("QUEUED", systemImage: "clock", tint: .secondary)
        case .failed(let reason)?:
            label("NO PROXY", systemImage: "exclamationmark.triangle.fill", tint: .red).help(reason)
        case .missing?, nil:
            EmptyView()
        }
    }

    private func label(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(.black.opacity(0.72), in: Capsule())
            .foregroundStyle(tint)
    }
}
```

- [ ] **Step 2: Show it on each card**

In `videoCard`, change the bottom `HStack` that holds the duration capsule to:

```swift
                        HStack {
                            ProxyBadge(status: store.proxyStore.statuses[asset.id])
                            Spacer()
                            Text(formatTime(asset.durationSeconds ?? 0))
                            // existing modifiers unchanged
                        }
```

- [ ] **Step 3: Add the Proxies toggle to the timeline toolbar**

Next to the existing play/split controls (find them with `grep -n "Ripple\|scissors" Sources/PerceptionEditor/VideoWorkspace.swift`):

```swift
                Toggle(isOn: $store.usesProxiesForPlayback) {
                    Label("Proxies", systemImage: "bolt")
                }
                .toggleStyle(.button)
                .help(store.timelineUsedProxyCount > 0
                      ? "Playing \(store.timelineUsedProxyCount) clip(s) from proxies. Export always uses originals."
                      : "Play from proxies when they are ready. Export always uses originals.")
```

- [ ] **Step 4: Build and check by hand**

Run: `./scripts/build-app.sh && open PerceptionEditor.app`
Then:
1. Import `/Volumes/ExSSD1/Pictures/110_PANA/P1107157.MOV`.
2. The card shows QUEUED, then a rising %, then PROXY. The rest of the UI stays responsive while that runs.
3. Add the clip to the timeline and scrub. The toggle help reads "Playing 1 clip(s) from proxies".
4. Toggle Proxies off and confirm playback still works from the original.

Record the result in the Verification table.

- [ ] **Step 5: Commit**

```bash
git add Sources/PerceptionEditor/VideoWorkspace.swift
git commit -m "Show proxy status on video cards and add a Proxies playback toggle"
```

---

### Task 8: Contracts, decision record, and status docs

**Files:**
- Create: `docs/decisions/2026-10-15-video-proxies.md`
- Modify: `docs/DATA_MODEL.md`, `docs/CURRENT_STATUS.md`, `docs/ROADMAP.md`, `docs/PERFORMANCE_TARGETS.md`, `README.md` ("What works now")

- [ ] **Step 1: Write the decision record**

```markdown
# Video proxies are a content-keyed disposable cache

Date: 2026-10-15
Status: accepted

## Context
Lumix S5 10-bit 4:2:2 H.264 UHD has no hardware decode on the target 8 GB M1. AVFoundation software decode reaches 45 fps (1.9× realtime) and drops to 12 fps if frames are requested as BGRA. Scrubbing, reverse play, and overlapping clips need more headroom than that.

## Decision
- Generate ProRes 422 Proxy (≤1920×1080, video only) with AVAssetReader → AVAssetWriter: 1.7× realtime to make, 345 fps to play.
- Key proxies by content (size + first/last MiB, SHA-256), not by path or asset ID, in `Proxy Cache` under Application Support. The `perceptionEditor.proxyDirectory` default overrides the location.
- Keep proxies out of `.pmedit` (schema stays 10). Preview resolves proxies; `MediaQuality.export` always resolves originals; audio is never proxied.

## Consequences
- About 16 GB of disk per hour of footage at 1080p. Generation is refused below estimate + 2 GiB free.
- Clearing the cache is always safe and costs only regeneration time.
- Preview sharpening/vignette radii are computed at proxy resolution and can differ slightly from export.
```

- [ ] **Step 2: Update the docs**

- `docs/DATA_MODEL.md`: in the caches paragraph, add "video proxies (content-keyed, see decisions/2026-10-15-video-proxies.md)" to the list of disposable caches.
- `docs/ROADMAP.md`: under V1.0, change "Proxy generation and original-media export" to note that proxy generation and export-quality source resolution are done, and that video file export is still the V0.3 "1080p and 4K export" item.
- `docs/PERFORMANCE_TARGETS.md`: add a video row: proxy generation ≥ 1.2× realtime on S5 UHD 4:2:2; proxy decode ≥ 120 fps.
- `docs/CURRENT_STATUS.md` and `README.md`: add one line on automatic proxies, the toggle, and that originals are used for export.

- [ ] **Step 3: Run the full gate**

Run: `./scripts/qa.sh`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add docs README.md
git commit -m "Document the video proxy cache contract and performance targets"
```

---

## Safety and performance

- **Originals:** All reads go through AVURLAsset or FileHandle in read mode. `proxyKeepsFramesTimingColorAndLeavesTheSourceUntouched` checks that the source bytes are unchanged.
- **Crash safety:** a `.partial.mov` is never treated as a proxy. A crash mid-encode leaves a partial file that the next attempt deletes before writing.
- **Memory:** one job at a time, reader output with `alwaysCopiesSampleData = false`, and the writer pulls frames as it is ready. Peak memory should stay well under 300 MB. Verify with Activity Monitor during the Task 7 manual check.
- **CPU:** generation uses every core at `.utility` priority. During the manual check, confirm photo editing stays responsive while proxies build. If it doesn't, the follow-up is to pause the queue while the photo workspace is active (out of scope here).
- **Out of scope:** video file export (V0.3 "1080p and 4K export" will call `makePlayerItem(quality: .export)` or its successor); per-project proxy cleanup and cache-size eviction; HEVC proxies; the 10-bit custom compositor and V-Log color management (separate plan).

## Verification

| Gate | Required check | Result and evidence |
| --- | --- | --- |
| Static/build | `git diff --check`; `./scripts/qa.sh` | PASS (substitute): `./scripts/qa.sh` was not runnable on this Mac, so it was not run as written. Evidence: `git diff --check` clean; full suite and app build via the CLT wrapper (`run-tests.sh --no-parallel`): 361 tests in 78 suites passed, 23 skipped (private inputs), 0 failed, build complete. `scripts/qa.sh` itself cannot run here (SDK 27.0 lacks SwiftUIMacros; `rg` is only a shell function so `agent-review.sh` exits 127). Its source review prints informational listings, and its one real check is `git diff --check`. |
| Unit/integration | `./scripts/test.sh --filter "Proxy|TimelineProxy|VideoProxyWorkflow"` | PASS (substitute): the filtered `scripts/test.sh --filter` command was not run as written; the proxy tests were covered by the full-suite CLT-wrapper run above (361 passed, 0 failed) |
| Runtime/UI | Task 7 Step 4 manual walkthrough | PASS with gaps, measured 2026-10-18 on the `feat/editor-redesign` build at `43234d9` (contains this branch's proxy pipeline except `0864b0b` source-timescale and `a57ab2d` Swift 6.1 init fix), not on this branch's head. Imported (Add Files in Place) `P1107172.MOV` (8-bit 4:2:0, video range, 4:56.8) and `P1107171.MOV` (S5 V-Log 10-bit 4:2:2, full range, 4:32.8). Card badge showed a rising % then PROXY for both; a cached proxy (`P1107210.MOV`) showed PROXY at once. `P1107171` added to the timeline: scrubbing and playback were smooth with Proxies on and with Proxies off (originals). Proxy files checked with ffprobe: ProRes 422 Proxy, 1920×1080, 10-bit 4:2:2, 23.976; frame counts match the sources (7116/7116, 6540/6540). V-Log levels: proxy is tagged video range and luma matches the full→video conversion of the source (YAVG 314.4→333.2 expected 333.2; YLOW 221→253 expected 253). NOT VERIFIED: the QUEUED badge (generation started at once, no queue), the Proxies toggle help text, and the walkthrough on this branch's own build. |
| Media quality | `RealVideoProxyTests` with `PME_VIDEO_SAMPLE` = S5 4:2:2 clip; frame-exact | PASS: real Lumix S5 clip (H.264 High 4:2:2 10-bit UHD, 23.976), 10 s trim, frame-exact, 1920×1080 |
| Performance | Proxy ≥ 1.2× realtime and UI responsive on the 8 GB M1 | Proxy generation PASS: 68.5 fps (about 2.9× realtime) at `.utility` QoS vs 28.8 fps gate (71.4 fps at the earlier `.userInitiated`) (debug build, opt-in `RealVideoProxyTests`); proxy decode 345 fps. Full-length generation in the app (measured 2026-10-18 on the `feat/editor-redesign` build at `43234d9` (contains this branch's proxy pipeline except `0864b0b` source-timescale and `a57ab2d` Swift 6.1 init fix), not on this branch's head; source read from the external SSD over USB 2.0): `P1107172` 3.5 GB in 108 s (2.75× realtime), `P1107171` V-Log 5.2 GB in 137 s (2.0× realtime, about 38 MB/s, so I/O-bound on the USB 2.0 link). Peak app memory 106 MB and 95 MB (`ps` RSS every ~2 s), under the 300 MB target. App CPU during generation averaged about 60–70%. UI responsiveness during generation: PASS by owner report (photo editing stayed responsive during the `P1107171` run). Separate finding on the redesign build: the app uses about 70–95% CPU while idle in the Video workspace (continuous SwiftUI transactions); tracked as its own fix on `feat/editor-redesign`. |

## Decisions, discoveries, and remaining work

- Product decision pending: default proxy location (Application Support on the internal drive vs. a folder on the external SSD).
- Video development is deferred in the roadmap until the photo gates pass. Starting this plan pulls one V1.0 item forward at the owner's request on 2026-10-15.
- Proxy dimensions round to the nearest even size (not down), so odd aspect ratios do not lose a pixel row or column unevenly.
- Proxy size uses the rotated render size (preferred transform applied), so portrait clips fit 1920×1080 correctly.
- Parallel test runs hung when the blocking AVFoundation sample loops ran on Swift's cooperative pool. ProxyGenerator now runs them on a dedicated serial DispatchQueue per job (`requestMediaDataWhenReady`).
- EditorStore forwards only proxy status case changes, not progress ticks, to bound view invalidation. Badges read progress directly.
- A proxy finishing in the background rebuilds the timeline only when already in timeline mode; it never takes over the viewer.
- Measured proxy generation was 71.4 fps in the real test, not the 40.8 fps of the earlier standalone probe.
- Test environment: this Mac has only Command Line Tools, so `scripts/test.sh` and `scripts/qa.sh` fail (default SDK 27.0 lacks SwiftUIMacros). Workaround: `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk` plus `-plugin-path` for the swift-testing macros; `build-app.sh` needs the same SDKROOT.
- Remaining: repeat the short walkthrough on this branch's own build (or after merge) to cover `0864b0b` and `a57ab2d`, and check the QUEUED badge (import two clips at once) and the Proxies toggle help text; decide the default proxy location. Measured proxy size is about 1.3 GB per 5 minutes of UHD footage (about 34 Mbit/s), written to the internal drive. The plan stays active until these are done.
