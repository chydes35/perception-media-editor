# Milestone: 10-bit video pipeline and V-Log color management

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task by task. Steps use checkbox (`- [ ]`) syntax for tracking. Task 0 is a measurement spike whose results can change Tasks 3–4. Do not skip it.

Status: active (Task 0 and the Task 2 proxy range fix done 2026-10-16, see [decision record](../../docs/decisions/2026-10-16-10bit-compositor.md); Task 1 next)
Roadmap sources: [V0.2 — LUT import and intensity control](../../docs/ROADMAP.md), [V0.3 — 1080p and 4K export](../../docs/ROADMAP.md). The 10-bit compositor, frame-exact timing, OCIO and scopes are new V0.3 work and must be added to the roadmap (Task 12).
Builds on: [video-proxy-pipeline.md](video-proxy-pipeline.md) (branch `feat/video-proxies`: `MediaQuality`, proxy-aware `TimelineCompositionService`)
Owner: video engine

**Product-order note.** [AGENTS.md](../../AGENTS.md) and the roadmap say video resumes after the photo gates. The owner pulled video forward with the proxy work. This milestone continues that choice. Photo users still benefit through LUT import (V0.2) and the HSL banding fix, which is shared code.

## User-visible outcome

The photographer drops Lumix S5 V-Log clips on the timeline and sees normal-looking Rec.709 color straight away. Detection uses the camera's own metadata, not the BT.709 tags, which are wrong for this footage. They can switch a clip between the Panasonic V-Log→V709 LUT they imported and the OpenColorIO ACES transform. They can grade with the existing sliders, HSL and curves without visible banding in skies. They can watch a waveform and vectorscope while the clip plays. They can export the cut as 10-bit ProRes 422 HQ or HEVC Main10, and every edit point lands on the exact frame they chose, even 23 minutes into a 23.976 fps clip.

## Facts measured on 2026-10-16 (target M1, CLT only)

| Finding | Evidence | Consequence |
| --- | --- | --- |
| The S5 V-Log clips are **full range** and tagged **BT.709 primaries, transfer and matrix**. | `ffprobe` on 7 V-Log files in `/Volumes/ExSSD1/Pictures/110_PANA`: `yuv422p10le`, `color_range=pc`, `bt709/bt709/bt709`, `24000/1001`, time base `1/24000`, `start_time=0`. | Do not trust the tags for transfer or gamut. Decode Y'CbCr with an explicit range and matrix. |
| The camera writes the real gamma and gamut in a QuickTime metadata item. | Format tag `com.panasonic.Semi-Pro.metadata.xml` contains `<CaptureGamma>V-Log</CaptureGamma>`, `<CaptureGamut>V-Gamut</CaptureGamut>`, `<EditUnit>1001/24000</EditUnit>`, `<Duration>` (frames). | Auto-detect V-Log from this item (Task 2). |
| Code values match V-Log's full-scale definition. | `signalstats` over the first 3 s: Y' min 96–181, max 814–931 (10-bit). V-Log puts 0% black at code 128 (0.125 × 1023). | Use Y'/1023 as the V-Log input. Range-remapping it to 64–940 loses about 14% of the levels. |
| The non-log files on the same card are 8-bit 4:2:0 video range. | `P1107172.MOV`, `P1107173.MOV`: `yuv420p`, `tv`, `CaptureGamma=STANDARD`. | The pipeline must handle mixed timelines of 8-bit Rec.709 and 10-bit V-Log. |
| `ProxyGenerator` reads every source as `kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange` (`x422`). | `Sources/PerceptionEditor/ProxyGenerator.swift:94`. | For full-range sources AVFoundation must rescale. Task 0 measures whether this clips or only re-quantizes. Task 2 fixes it. |
| The machine has no `metal` compiler and no `cmake`. | `xcrun -f metal`: not found. `cmake`: not found. Homebrew is present. | Compile Metal shaders at runtime from source strings (`MTLDevice.makeLibrary(source:options:)`). Do not add `.metal` files to the package. OCIO cannot be built from source here without extra tooling. |
| OCIO's built-in transform exists under the expected name. | `src/OpenColorIO/transforms/builtins/PanasonicCameras.cpp`: `PANASONIC_VLOG-VGAMUT_to_ACES2065-1` = inverse camera log (base 10, b 0.00873, c 0.241514, d 0.598206, break 0.01) then a V-Gamut→AP0 Bradford matrix (V-Gamut R 0.730/0.280, G 0.165/0.840, B 0.100/−0.030, D65). `GpuLanguage` includes `GPU_LANGUAGE_MSL_2_0`. PyPI `opencolorio` 2.5.2 (2026-05-13); Homebrew bottle 2.5.1. | Phase B can generate Metal shaders offline from the pinned Python wheel (Task 9). |
| The current composition uses Core Image, Double seconds and timescale 600. | `TimelineCompositionService.swift:171–178, 258–284, 298–326`; `TimelineClip` stores `timelineStartSeconds`, `sourceStartSeconds` and `durationSeconds` as `Double`. | One 23.976 frame is 25.025 ticks at timescale 600, so edit points round to the tick. Ripple (`EditorStore.swift:1577`) and trim (`:1211–1229`, 0.25 s minimum) accumulate Double seconds that are not on frame boundaries. |
| The HSL cube is built for 8-bit output. | `ColorGrading.swift:316–318`: a 48³ cube, "under 2 levels of 255" (about 8 levels of 1023), trilinear in `CIColorCubeWithColorSpace`, clamped 0…1. Curves use 256 samples (`curveData`). | Task 5 fixes this. |

## Scope and dependencies

**Included:** a custom `AVVideoCompositing` compositor (half-float Metal, never 32BGRA), frame-exact clip timing (schema 11), source color detection, `.cube` LUT import and intensity (photo and video), OCIO-generated V-Log→ACES→Rec.709 shaders, the 10-bit HSL and curves fix, waveform and vectorscope scopes, 10-bit timeline export (ProRes 422 HQ, HEVC Main10), and a proxy range fix.

**Excluded:** HDR/EDR output, linking OCIO at runtime for user `.ocio` configs (Task 10 records the decision and stays deferred), LUTs inside presets, mixed frame rates beyond a warning, transitions or titles, a full Metal port of `MediaColorRenderer`'s Core Image adjustments, and photo scopes.

**Affected systems:** `TimelineCompositionService`, `EditorModels` (`TimelineClip`, `MediaAsset`, `EditorProject`), `EditorStore` timeline edits, `ProxyGenerator` (with a cache-key version), `ColorGrading`, `MediaColorRenderer`, `VideoWorkspace`, and photo LUT controls.

**Decisions for the owner** (record each in `docs/decisions/`):

1. **Third-party code.** Phase B ships shader text generated by OCIO (BSD-3) plus a notice, without linking the library. Linking it would break the "Package.swift unchanged / no third-party packages" rule. This plan recommends generated shaders now and defers linking (Task 10).
2. **Panasonic LUT redistribution.** Do not bundle `VLog_to_V709_forV35_ver100.cube`. The user downloads it from Panasonic and imports it. Tests take it from `PME_VLOG_LUT`.
3. **Default V-Log view.** Choose between the Panasonic LUT (when imported) and ACES 2.0 SDR 100 nits Rec.709 (OCIO). Recommendation: OCIO once Task 9 passes, because it needs no download and keeps highlight headroom through grading.

## Architecture

```
AVAsset track ──(xf22 / x422 / 420v; never BGRA)──► TimelineVideoCompositor (AVVideoCompositing, serial queue)
  1. CVMetalTextureCache → luma + chroma MTLTextures (zero copy)
  2. Metal: Y'CbCr → R'G'B' half float, explicit range + matrix from SourceColorDescriptor
  3. Metal: input transform per clip
        Phase A: 3D LUT (tetrahedral, .cube domain, intensity mix) → Rec.709 display-encoded
        Phase B: OCIO V-Log/V-Gamut → linear Rec.709 (unclamped)
        Rec.709 sources: identity (decode only)
  4. Core Image on the same MTLCommandQueue, workingFormat .RGBAh, linear extended sRGB:
        MediaColorRenderer.render(..., includesGeometry: false)   ← shared photo/video contract
        HSL + LUT stages inside it run as MetalColorKernel (CIImageProcessorKernel) using the same shader as video
  5. Phase B only: OCIO ACES 2.0 SDR 100 nits Rec.709 output transform
  6. Fit into the render size (proxy), write the output buffer: 64RGBAHalf (preview) or x422 (export)
  7. Scope tap: downsample the output to 512 px wide into a single-slot mailbox → ScopeRenderer
```

- **Why Core Image stays for the sliders.** `highlightShadowAdjust` and `vibrance` are Apple's own filters. Re-implementing them in Metal would break the photo/video contract in [AGENTS.md](../../AGENTS.md). Rendering Core Image in half float on our command queue keeps 10-bit precision. Steps 2, 3, 5 and 6 are ours. A full Metal port is a later decision.
- **Shaders** live as Swift string constants in `MetalShaderSources.swift`. `MetalPipelineCache` compiles them once at first use, off the main actor, and caches them per device. Compile failures surface as a composition warning and fall back to the Core Image path.
- **Instructions.** There is one `TimelineCompositionInstruction` (an `NSObject` conforming to `AVVideoCompositionInstructionProtocol`) per clip segment, with a `timeRange` built from frames. Each carries an immutable `Sendable` `ClipRenderRecipe` (source track ID, color descriptor, input transform, adjustments, render size). This replaces `TimelineColorSegment.contains(seconds)`.
- **Memory (8 GB).** At 4K, a half-float RGBA frame is 66 MB and an `x422` frame is 33 MB. Never request 64RGBAHalf from the decoder at 4K unless Task 0 shows it is cheaper. Keep at most 3 output buffers in the pool, plus a fixed set of intermediate textures sized to the render size. Rebuild them only when `renderContextChanged` changes the size. Run each frame inside `autoreleasepool`. On memory pressure, call `CVMetalTextureCacheFlush` and `CIContext.clearCaches()`.

## File structure

| File | Responsibility |
| --- | --- |
| Create `Sources/PerceptionEditor/FrameTime.swift` | `FrameRate`, frame↔`CMTime` conversion, rounding policy |
| Create `Sources/PerceptionEditor/SourceColor.swift` | `SourceColorDescriptor`, Panasonic metadata parser, `ColorInputTransform` |
| Create `Sources/PerceptionEditor/CubeLUT.swift` | `.cube` parser and validation, `LUTLibrary` (content-addressed copies), `LUTReference` |
| Create `Sources/PerceptionEditor/MetalShaderSources.swift`, `MetalPipelineCache.swift` | Shader text, runtime compilation, texture cache |
| Create `Sources/PerceptionEditor/MetalColorKernel.swift` | `CIImageProcessorKernel` wrapper so photos use the same HSL and LUT shader |
| Create `Sources/PerceptionEditor/TimelineVideoCompositor.swift`, `TimelineCompositionInstruction.swift` | The custom compositor |
| Create `Sources/PerceptionEditor/OCIOGeneratedShaders.swift` (generated) and `Resources/OCIO/*.bin` (LUT textures, if any) | Phase B transforms |
| Create `Sources/PerceptionEditor/ScopeRenderer.swift`, `ScopeView.swift` | Waveform and vectorscope |
| Create `Sources/PerceptionEditor/TimelineExporter.swift` | 10-bit export through `AVAssetReaderVideoCompositionOutput` → `AVAssetWriter` |
| Create `scripts/ocio/generate-shaders.py`, `scripts/ocio/requirements.txt` (pinned with hashes) | Offline OCIO shader generator |
| Modify `TimelineCompositionService.swift`, `EditorModels.swift`, `ProjectDocument.swift`, `EditorStore.swift`, `ColorGrading.swift`, `MediaColorRenderer.swift`, `ProxyGenerator.swift`, `ProxyFingerprint.swift`, `VideoWorkspace.swift`, `PhotoWorkspace.swift` | Integration |
| Tests: `FrameTimeTests`, `TimelineFrameExactTests`, `ProjectMigration11Tests`, `SourceColorTests`, `CubeLUTTests`, `MetalColorKernelTests`, `TimelineVideoCompositorTests`, `ColorGradingTests` (extend), `OCIOShaderTests`, `ScopeRendererTests`, `TimelineExporterTests`, `RealVideoColorTests` (opt-in) | See Test strategy |
| Docs: `docs/decisions/2026-10-xx-10bit-compositor.md`, `…-ocio-generated-shaders.md`, `…-frame-exact-timing.md`; update `DATA_MODEL.md`, `ARCHITECTURE.md`, `PERFORMANCE_TARGETS.md`, `TESTING_STRATEGY.md`, `CURRENT_STATUS.md`, `ROADMAP.md` | Contracts |

**Test command on this Mac** (`scripts/test.sh` fails as written with CLT only):

```bash
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing --filter <Suite>
```

Below, `run-tests <Suite>` means that command. Fixing `scripts/test.sh` to detect CLT is out of scope here; it is listed as a follow-up.

**Real-footage fixtures** (read-only, never written, moved or opened for writing):

| Env var | File | Use |
| --- | --- | --- |
| `PME_VLOG_SHORT` | `P1107158.MOV` (3.0 s, V-Log, 10-bit 4:2:2 full range) | Fidelity and LUT gates |
| `PME_VLOG_SKY` | `P1107210.MOV` (11.5 s, V-Log) | Banding and visual review |
| `PME_REC709_8BIT` | `P1107172.MOV` (8-bit 4:2:0 video range, STANDARD) | Mixed-timeline gate |
| `PME_VIDEO_SAMPLE` | `P1107157.MOV` (1386 s, 33 240 frames) | Frame-exact drift and throughput gates |
| `PME_VLOG_LUT` | the user's downloaded `VLog_to_V709_forV35_ver100.cube` | LUT gates |
| `PME_VIDEO_OUTPUT_DIR` | disposable directory outside `110_PANA` | Exports and reference frames |

---

## Plan and progress

### Task 0: Spike — pixel formats, range and throughput (measure first, no product code)

Write a throwaway probe in the scratchpad, not in `Sources/`. It runs a minimal `AVVideoCompositing` class with an `AVPlayerItemVideoOutput` and an `AVAssetReaderVideoCompositionOutput` against `PME_VLOG_SHORT`, `PME_VIDEO_SAMPLE` (first 60 s) and a proxy of each.

**Result (2026-10-16): done.** See the [decision record](../../docs/decisions/2026-10-16-10bit-compositor.md). Summary:

- Every format decodes through the compositor at about 47 fps.
- `xf22` is bit-exact with ffmpeg. `x422` from a full-range source is **luma + 64**, not a range conversion.
- `64RGBAHalf` costs about 150 MB more in `VTDecoderXPCService`.
- The existing proxies store luma + 64 tagged video range, so they **preview about 17% brighter** and clip above original code 876.
- `x422` output goes into ProRes 422 HQ and HEVC Main10 at 47.5 fps. AVPlayer plays the 4K original in real time through the compositor.
- OCIO MSL compiles at runtime (MSL 2.4) and matches CPU within 5.8e-4. The latest studio config is ACES 2.0, whose output needs two 1D textures.

The decision is xf22-first YCbCr input, our own decode and encode, and a proxy range fix in Task 2.

- [x] For each `sourcePixelBufferAttributes` format — `xf22` (`422YpCbCr10BiPlanarFullRange`), `x422`, `kCVPixelFormatType_64RGBAHalf` and `420v` (for the 8-bit file) — record: does the compositor receive that format; decode fps through the compositor (original 4K and 1080p proxy); process footprint (`footprint`/`vmmap --summary`); and whether buffers are IOSurface-backed (needed for zero-copy `CVMetalTextureCache`).
- [x] Range check: decode frames 0, 36 and 71 of `P1107158` with `xf22` and with `x422`. Compare 64 pixel positions against `ffmpeg -i … -vf "scale=in_range=pc:out_range=pc,format=yuv422p10le" -f rawvideo` (Y' and Cb/Cr code values). Record whether `x422` clips (values pinned at 64/940) or rescales.
- [x] Check the same for the existing proxy. Record whether its luma code values follow `round(64 + Y'·876/1023)`, or are clipped.
- [x] Output format: confirm that AVPlayer displays a `64RGBAHalf` compositor output tagged `AVVideoColorPrimaries_ITU_R_709_2`, and that an `x422` output feeds `AVAssetWriter` ProRes 422 HQ and HEVC Main10 without an extra conversion.
- [x] Compile one OCIO-generated MSL function (from Task 9's script, run early) with `makeLibrary(source:)`. Record the MSL language version needed.
- [x] Write the results into `docs/decisions/2026-10-xx-10bit-compositor.md`, a table with one row per format, and pick the formats. **Decision rule:** prefer YCbCr biplanar plus our own Metal decode unless 64RGBAHalf decodes at ≥ 95% of its fps and uses less memory. Never use 32BGRA.

**Exit:** a decision record with measured numbers. If the compositor cannot receive a 10-bit format at all, stop and escalate to the owner. The fallback is `AVAssetReader`-driven rendering for preview frames, which changes Tasks 4 and 8.

### Task 1: Frame-exact time model (schema 10 → 11)

**Interfaces:**

```swift
/// A frame rate as an exact frame duration, e.g. 1001/24000 for 23.976.
struct FrameRate: Codable, Hashable, Sendable {
    var frameDuration: Int64      // 1001
    var timescale: Int32          // 24000
    static let ntsc23976 = FrameRate(frameDuration: 1001, timescale: 24000)
    func time(ofFrame n: Int64, origin: CMTime = .zero) -> CMTime   // origin + n·frameDuration, exact
    func frame(containing t: CMTime, origin: CMTime = .zero) -> Int64  // floor
    func nearestFrame(toSeconds s: Double) -> Int64                  // round half to even; migration and UI input only
}
struct TimelineClip { …; var timelineStartFrame: Int64; var sourceStartFrame: Int64; var durationFrames: Int64 }
// sourceStartFrame and durationFrames count in the asset's own FrameRate; timelineStartFrame counts in the project's sequence rate.
struct MediaAsset { …; var frameRate: FrameRate?; var firstFrameTime: CMTimeValue?/timescale (exact, from the track's timeRange.start) }
struct EditorProject { …; var sequenceFrameRate: FrameRate? /* first clip's rate; default ntsc23976 */ }
```

- [ ] **Red test first:** `TimelineFrameExactTests.legacySecondsLoseFramesAt23976`. Write a frame-numbered fixture: extend `writeTestMovie` to draw the frame index as a binary bar code in the top rows, 24000/1001, 1 200 frames. Split at frame 1 117, ripple 30 one-frame trims, and decode every output frame of the composition through `AVAssetImageGenerator` with zero tolerance. Expect output frame k to read source index k. It fails on today's code, which proves the bug. Then switch the test to the new API.
- [ ] Rewrite every use of `*Seconds` in `TimelineCompositionService` and `EditorStore` timeline edits to work in frames: insert, split, trim (minimum 6 frames instead of 0.25 s), ripple cursor, active-clip lookup, and playhead snapping to the frame shown. Audio uses the same `CMTime`s. Fades stay as Double durations, converted at the sequence timescale.
- [ ] Composition: set `naturalTimeScale` to the sequence timescale (24000) and the video composition's `frameDuration` to the sequence rate.
- [ ] Migration: in `ProjectDocument`, read schema ≤ 10 clips into a `LegacyClipTiming` (seconds). After open, the store fills in `MediaAsset.frameRate` and `firstFrameTime` with an async track load (like the pixel-dimension backfill), then converts with `nearestFrame(toSeconds:)`. An offline asset keeps its legacy seconds, which are written back unchanged, until relink. Saving writes schema 11 with frame fields, plus legacy seconds only for clips that are still unconverted.
- [ ] Tests: `FrameTimeTests` (exactness at frames 0, 1, 33 239 and 10⁹; round-trip `frame(containing: time(ofFrame:))`; 25, 29.97 and 59.94 fps); `ProjectMigration11Tests` (a schema-10 fixture file opens, converts and saves as 11; reopening gives identical frames; an offline asset keeps its seconds; a schema-12 file still throws `unsupportedSchema`); and the frame-numbered composition test going green.
- [ ] Real gate **G6** (below).

### Task 2: Source color descriptor, Panasonic detection and the proxy range fix

```swift
enum YCbCrRange: String, Codable, Sendable { case video, full }
enum SourceTransfer: String, Codable, Sendable { case rec709, vLog, unknown }
enum SourceGamut: String, Codable, Sendable { case rec709, vGamut, unknown }
struct SourceColorDescriptor: Codable, Hashable, Sendable {
    var bitDepth: Int; var chroma: String /* "4:2:2" */; var range: YCbCrRange
    var matrix: String /* "709" */; var transfer: SourceTransfer; var gamut: SourceGamut
    var detectedFrom: String /* "panasonic-xml" | "format-description" */
}
enum ColorInputTransform: Codable, Hashable, Sendable {
    case automatic                // descriptor decides
    case none                     // show code values as they are (flat V-Log)
    case lut(LUTReference)        // Phase A
    case aces(OCIOViewID)         // Phase B
}
```

- [ ] Parse `com.panasonic.Semi-Pro.metadata.xml` (loaded with `AVAsset.load(.metadata)`, key space QuickTime metadata) using `XMLParser`. Take `CaptureGamma`, `CaptureGamut`, `BitDepth`, `EditUnit`. Range and matrix come from the format description extensions (`kCMFormatDescriptionExtension_FullRangeVideo`, `…YCbCrMatrix`). Do not use the transfer and primaries tags when Panasonic metadata disagrees.
- [ ] Store the descriptor on `MediaAsset` (schema 11, optional). It is backfilled on open together with the frame rate. Store `colorInputByAssetID: [UUID: ColorInputTransform]` on `EditorProject`. Color input is a property of the source file, not of a clip.
- [x] **Done 2026-10-16** (red test first; see the decision record's "Proxy fix result"). Implementation note: VideoToolbox's `VTPixelTransferSession` does the scaling correctly, so no Metal pass was needed. Old v1 proxy files are orphaned, not deleted. A cache sweep is a follow-up. **Proxy range fix (priority: today's proxies preview V-Log about 17% too bright; see the decision record).** `ProxyGenerator` reads full-range sources as `xf22`. A Metal (or vImage) pass converts to correctly scaled video range: Y' = 64 + Y'·876/1023, C = 512 + (C − 512)·896/1023, rounded. The frames are appended through `AVAssetWriterInputPixelBufferAdaptor` as `x422`, tagged video range. AVFoundation's own full→video conversion only adds 64 to luma, so never hand it full-range buffers to convert. Add a red test first: a full-range fixture's proxy, read back as RGB, matches the original within 2/1023 (it fails today by about 17%). The proxy's own range is recorded in the proxy validation and read from the proxy's format description at composition time, never assumed. Add a generator version to the cache key (`ProxyFingerprint.key` gets a `v2|` prefix), so v1 proxies regenerate. Do not delete them eagerly; the existing reuse and cleanup logic retires them.
- [ ] Tests: `SourceColorTests` uses checked-in XML snippets (V-Log, STANDARD, malformed, missing). The test fixture writer gains a full-range variant. A proxy of a full-range fixture keeps code values within 2 levels of 1023 (`ProxyGeneratorTests.fullRangeSourceKeepsCodeValues`).

### Task 3: Metal runtime, YCbCr decode kernel

- [ ] `MetalPipelineCache` (an actor; created once): device, one `MTLCommandQueue` shared with a `CIContext(mtlCommandQueue:options: [.workingFormat: CIFormat.RGBAh, .workingColorSpace: extendedLinearSRGB, .cacheIntermediates: false])`, a `CVMetalTextureCache`, and compiled pipelines keyed by function name. Shader source uses MSL 2.4 (or Task 0's choice) and half precision for storage, float for math.
- [ ] Kernel `decodeYCbCr`: takes luma (`r16Unorm`) and chroma (`rg16Unorm`) textures (10-bit formats keep the value in the **upper** 10 bits of each 16-bit sample, so code value = `round(v · 65535 / 64)`; 8-bit `420v` uses `r8Unorm`/`rg8Unorm`), the range, the matrix coefficients (Kr, Kb for 709/601/2020) and the bit depth. It outputs R'G'B' half float, unclamped. Chroma is upsampled bilinearly for 4:2:2 and 4:2:0 with siting from the format description (default: left/co-sited for 4:2:2).
- [ ] Kernel `encodeYCbCr` (for `x422` output to export): R'G'B' half float → BT.709 video-range Y'CbCr 10-bit with 4:2:2 chroma averaging (co-sited), clamped to 4–1019 as ProRes allows. Kernel `fitToRenderSize` (aspect-fit with black, bilinear) replaces the Core Image transform-and-composite in today's handler.
- [ ] Tests (`MetalColorKernelTests`): `encodeYCbCr(decodeYCbCr(x))` round-trips 10-bit code values within 1. Synthetic CVPixelBuffers (xf22, x422, 420v) with known code values decode to expected R'G'B' within 0.25/1023. Neutral grey stays neutral. Black, white and 75% bars match BT.709 equations computed in Double. The tests skip with a recorded reason when no Metal device is present, so CI reports "skipped", not "pass".

### Task 4: Custom compositor replaces the CIFilter handler

- [ ] `TimelineVideoCompositor: NSObject, AVVideoCompositing, @unchecked Sendable`, with a private serial `DispatchQueue` at `.userInitiated`:
  - `sourcePixelBufferAttributes`: Task 0's formats (e.g. `[xf22, x422, 420v]`), `kCVPixelBufferMetalCompatibilityKey: true`, never `32BGRA`.
  - `requiredPixelBufferAttributesForRenderContext`: `64RGBAHalf` for preview, `x422` for export (Task 0). These are chosen from a `MediaQuality` passed through the instruction.
  - `supportsWideColorSourceFrames = true`, `canConformColorOfSourceFrames = true` (macOS 12+), `supportsHDRSourceFrames = false` for now. Per the SDK header (`AVVideoCompositing.h`), a source whose pixel format is **not** in `sourcePixelBufferAttributes` gets converted in both format **and** color space by the engine. So the list must cover every source format on the timeline: `xf22`, `x422`, `420v`, `420f`, plus `xf20`/`x420` for 10-bit 4:2:0 HEVC. Task 0 confirms that a listed format arrives unconverted. The video composition's `colorPrimaries`/`colorTransferFunction`/`colorYCbCrMatrix` also define the *required source* color space. Keep them at 709 to match the sources' tags, so the engine never converts V-Log pixels.
  - `startRequest`: look up the instruction's recipe, run steps 1–6 on one command buffer, then `finish(withComposedVideoFrame:)` in its completion handler. It honors `cancelAllPendingVideoCompositionRequests` by bumping a generation counter, and cancelled requests call `finishCancelledRequest()`.
- [ ] `TimelineCompositionService.makePlayerItem`: build instructions from frame ranges, set `customVideoCompositorClass`, `frameDuration`, `renderSize` (proxy-fit logic moves into the recipe), and `colorPrimaries`/`colorTransferFunction`/`colorYCbCrMatrix = 709`. Keep the neutral fast path: no compositor when every clip is Rec.709, neutral, unproxied and at render size. V-Log clips always need the compositor.
- [ ] `makeSourcePlayerItem` uses the same compositor for one clip, so the source viewer shows V-Log through its input transform.
- [ ] Remove `applyingCIFiltersWithHandler`, `TimelineColorSegment` and `SendableVideoComposition` after the tests below pass.
- [ ] Tests (`TimelineVideoCompositorTests`, using `AVAssetReaderVideoCompositionOutput` to pull frames headlessly):
  - A neutral clip round-trips its code values within 1/1023 (proves no 8-bit stage). Use a 10-bit ramp fixture; count distinct output levels; expect ≥ 1 000 of 1 024.
  - Graded output matches `MediaColorRenderer.render` on the same decoded frame within 2/1023 (shared contract).
  - **No look change for Rec.709 clips.** Decoded Rec.709 R'G'B' enters Core Image linearized with the same ITU-R 709 transfer Core Image applies to 709-tagged sources today, so a graded 8-bit Rec.709 clip matches the old CIFilter-handler output within 4/1023 (the old path was 8-bit). Capture the old output as a golden PNG16 *before* removing the handler. Phase A LUT output (V709) is linearized the same way.
  - Mixed timeline (8-bit 420v Rec.709 clip + 10-bit full-range "V-Log" fixture + proxy): one render size, the instruction boundary lands exactly on the frame, no crash. This replaces `mixedTimelineRendersAtProxySize`'s Core Image assumptions.
  - Cancellation: seeking 50 times in 1 s leaves no requests pending and does not grow the buffer pool.
  - Existing proxy suites (`TimelineProxyCompositionTests`, `VideoProxyWorkflowTests`) stay green, including `proxyReadyRebuildKeepsPosition`.

### Task 5: Banding — HSL and curves at 10-bit precision

Root cause: the 48³ trilinear cube interpolates a function with a hue discontinuity and a chroma-gated strength. The cube's error budget was set in 8-bit levels, and the output is clamped to 0…1.

- [ ] Port `ColorGrading.applyHSL` (with `rgbToHSL`, `hslToRGB`, band blend and smoothstep) to a Metal function `applyHSL`, evaluated **per pixel, analytically**. The band table goes in a constant buffer (8 × 3 floats). The cube is gone from the video path.
- [ ] Photos: `MetalColorKernel` (`CIImageProcessorKernel`, `outputFormat = .RGBAh`) runs the same shader, so photo and video HSL are the same code. `MediaColorRenderer` uses it in place of `CIColorCubeWithColorSpace` for HSL. It runs in the sRGB-encoded domain like today: convert in, run, convert out with `CIFilter.linearToSRGBToneCurve`/`sRGBToneCurveToLinear`, which are unclamped. Keep `hslCube` behind a fallback for devices where the kernel fails. Raise its default dimension to 64 and drop its comment's 8-bit claim.
- [ ] Curves: `curveData(samples:)` defaults to 1 024 samples.
- [ ] Tests (extend `ColorGradingTests`):
  - Over a 129³ grid plus 10⁶ seeded random colors, the GPU `applyHSL` matches the Double reference within 1/1023 (max) and 0.25/1023 (mean).
  - A 1 024-step grey ramp with HSL saturation +1 on all bands stays monotonic, with no step > 2/1023.
  - A synthetic sky gradient (hue 200–230°, 4 000 px wide, 10-bit) with Blue saturation +0.6 and luminance −0.4 has no adjacent-pixel step > 2/1023, while today's cube path is shown to exceed it (red first).
  - Photo vs video HSL agree within 1/1023.
  - The cube fallback at 64³ stays within 2/1023.
- [ ] Real gate **G5**.

### Task 6: `.cube` LUT import and intensity (Phase A, roadmap V0.2)

- [ ] `CubeLUT` parser: `TITLE`, `LUT_3D_SIZE` 2–65, `LUT_1D_SIZE` up to 65 536, `DOMAIN_MIN`/`DOMAIN_MAX`, comments, CRLF, and both locale-proof decimals and scientific notation. It rejects NaN, the wrong number of rows, mixed 1D/3D and files over 64 MB, with readable messages. Red varies fastest (Adobe spec).
- [ ] `LUTLibrary`: import copies the file into the shoot folder `LUTs/<sha256-prefix>-<name>.cube`, so the project is self-contained. The original file is never modified. `LUTReference { contentHash, displayName }`. A missing or corrupt LUT gives a visible warning and renders without it. It never crashes or blocks.
- [ ] Model: `PhotoAdjustments.lut: LUTApplication? { reference, intensity 0…1 }` (optional field, decodes from old files). Video V-Log input uses `ColorInputTransform.lut` (Task 2) before the adjustments. A creative LUT on a clip uses `PhotoAdjustments.lut` after them, the same as on photos.
- [ ] Rendering: a 3D `MTLTexture` (`rgba16Float`; 65³ = 2.2 MB), **tetrahedral** interpolation in the shader, domain scaling, and `mix(input, lut, intensity)`. Photos use `MetalColorKernel`. Input-transform LUTs apply to decoded R'G'B' code values (normalized by 1023 for full range). This matters: going through Core Image's 709-tagged color space would linearize the V-Log values first.
- [ ] UI: a "Source color" picker in the video inspector (Automatic / None / LUT… / ACES) and "LUT + Intensity" in Photo Color and Video Color. Imports go through `NSOpenPanel`; work stays off the main actor.
- [ ] Tests (`CubeLUTTests`): the parser accepts or rejects 12 crafted files. An identity 33³ LUT is a no-op within 0.5/1023. A known analytic LUT (a channel swap plus gamma 2.0) at 17³ matches the analytic result. Tetrahedral interpolation is exact on lattice points. Intensity 0 is bit-identical to the input. A project referencing a deleted LUT opens with a warning. Re-importing the same bytes deduplicates.
- [ ] Real gate **G3**.

### Task 7: Waveform and vectorscope (Metal)

- [ ] Tap: on preview requests, and only while the scope panel is visible, the compositor encodes a `downsampleForScope` kernel into the same command buffer. It writes the output frame to a 512 × 288 `rgba16Float` texture in a single-slot mailbox (an atomic swap; latest wins; never blocks the compositor). It runs at most every second frame during playback, and once on seek or pause.
- [ ] `ScopeRenderer` (an actor with its own command queue):
  - Waveform: luma, or an RGB parade, in 512 columns × 1 024 bins of `atomic_uint`, then a normalize/log-gain kernel into a `bgra8Unorm` texture. Guides at 0, 64, 512, 940 and 1023 code values (IRE labels optional).
  - Vectorscope: a 512 × 512 bin grid in BT.709 Cb/Cr, with targets for 75% and 100% bars and a skin-tone line.
  - Display: `ScopeView` (an `NSViewRepresentable` `MTKView`, `isPaused = true`, `enableSetNeedsDisplay`), like `MetalPhotoCanvas`.
- [ ] The scopes measure the graded output in display encoding. A "Source" toggle measures the decoded code values before the input transform, which is useful for exposing V-Log (grey at about 433).
- [ ] Tests (`ScopeRendererTests`): synthetic 75% bars give waveform peaks at the expected code values ± 1 bin and vectorscope peaks in the target boxes. A flat grey frame puts all its vectorscope counts in the center bin. The tap never holds more than one texture. With the panel hidden, no scope work is encoded (a counter).
- [ ] Real gate **G9**.

### Task 8: 10-bit timeline export

- [ ] `TimelineExporter` (an actor): `makePlayerItem(… quality: .export)` builds the composition. Frames flow through `AVAssetReaderVideoCompositionOutput` (the same compositor and instructions, `x422` output) into `AVAssetWriter`. Presets: **ProRes 422 HQ** (`.proRes422HQ`) and **HEVC Main10** (`.hevc`, `AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel`). Both are tagged Rec.709, with sizes UHD and 1080p. Audio is passed through as AAC or LPCM from the composition's audio mix.
- [ ] Safety: write to `<name>.partial.mov` in the chosen folder and publish atomically with the existing `ExportFileSafety` patterns. Never use a source path as output. Use a disk guard like the proxy store's. Show progress and support cancel. Only one export runs at a time, and proxy generation pauses while exporting.
- [ ] Tests (`TimelineExporterTests`): exporting the frame-numbered fixture keeps frame k as source k. Frame count = Σ durationFrames. The ProRes output is 10-bit (`kCVPixelFormatType_422YpCbCr10` readback) and its distinct-level count on the ramp fixture is ≥ 1 000. Cancel leaves no `.partial.mov`. Export never opens proxies, even when proxy URLs are passed.
- [ ] Real gates **G1**, **G6** and **G7**.

### Task 9: OpenColorIO, Phase B1 — generated MSL shaders

- [ ] `scripts/ocio/generate-shaders.py` runs in an isolated venv in the scratchpad (`python3 -I`, `pip install -r scripts/ocio/requirements.txt --require-hashes`, `opencolorio==2.5.2` and `numpy`, which `Texture.getValues()` needs). For each transform it builds a `GpuShaderDesc` with `language=GPU_LANGUAGE_MSL_2_0`, a unique `functionName`/`resourcePrefix`, and `getShaderText()`. It writes `Sources/PerceptionEditor/OCIOGeneratedShaders.swift` (string constants plus a header recording the OCIO version, config name and script hash). Any 1D/3D LUT textures go to `Resources/OCIO/<prefix>_<name>.bin` as half floats, with a JSON manifest. It also writes **golden data**: 4 096 seeded inputs and outputs from `processor.getDefaultCPUProcessor()`, into `Tests/PerceptionEditorTests/Fixtures/ocio-golden.json`.
- [ ] Transforms (from the built-in `ocio://studio-config-latest`, recording the resolved version):
  1. `vlog_vgamut_to_lin_rec709`: built-in `PANASONIC_VLOG-VGAMUT_to_ACES2065-1`, then ACES2065-1 → linear Rec.709. Unclamped. Feeds Core Image.
  2. `lin_rec709_to_rec1886_aces20`: `DisplayViewTransform` from `Linear Rec.709 (sRGB)` to display `Rec.1886 Rec.709 - Display`, view `ACES 2.0 - SDR 100 nits (Rec.709)`. Task 0 found that the 2.5 studio config (`studio-config-v4.0.0_aces-v2.0_ocio-v2.5`) has no ACES 1.3 view. This transform needs the two `texture1d` tables (`reach_m_table_0`, 363 entries, red channel; `gamut_cusp_table_0`, 363 entries, RGB). Upload the RGB table as `rgba32Float`.
  3. Optional: ACES 1.3 SDR from `ocio://studio-config-v2.2.0_aces-v1.3_ocio-v2.4 (the newest ACES 1.3 built-in config in 2.5.2)`, if the owner prefers the older look (G8).
- [ ] Runtime: `MetalPipelineCache` concatenates the OCIO function text with our kernel wrapper and binds textures by the manifest. The compositor runs steps 3 and 5 for `ColorInputTransform.aces`.
- [ ] Shader regeneration is a manual, documented step. CI checks that the generated file's recorded script hash matches the script, so generator edits cannot drift silently.
- [ ] Licensing: add `Resources/ThirdPartyNotices/OpenColorIO-BSD-3.txt` and mention it in the About window or the existing notices location.
- [ ] Tests (`OCIOShaderTests`): each GPU transform matches the golden CPU outputs within 1e-3 absolute (half float) in the 0…1 encoded range and 0.2% relative above it. An independent Swift Double V-Log oracle (`10^((x−d)/c) − b`, with OCIO's linear segment below the break) plus the V-Gamut→Rec.709 Bradford matrix agree with transform 1 within 1e-4. The integration test asserts that 18% grey (code 433/1023) through transform 1 gives linear about 0.18.
- [ ] Real gate **G4**.

### Task 10: OpenColorIO, Phase B2 — runtime library (decision only, deferred)

- [ ] Write `docs/decisions/2026-10-xx-ocio-generated-shaders.md`. It explains why shaders are generated rather than linked: no cmake or Xcode on the target, the "no third-party packages" rule, and C++ interop cost. It names the trigger for B2 (the user needs custom `.ocio` configs or camera IDTs beyond the generated set) and the B2 path: a static OCIO built by script into an XCFramework `binaryTarget`, a small C shim, and minizip/expat/yaml-cpp/pystring/Imath built statically, all with notices. Nothing is implemented in this milestone.

### Task 11: Memory pressure and performance instrumentation

- [ ] The compositor reports per-frame GPU time (`MTLCommandBuffer.gpuStartTime/gpuEndTime`) and dropped requests through `PhotoPreviewDiagnostics`-style logging (`os_signpost` with "VideoCompositor" intervals).
- [ ] Memory-pressure source: flush the texture cache, clear CI caches, and drop the scope textures.
- [ ] Extend `scripts/profile-memory.sh` (or add `scripts/profile-video.sh`) to record peak footprint for G7.

### Task 12: Docs and roadmap

- [ ] `DATA_MODEL.md`: schema 11 (frames, `FrameRate`, descriptor, `colorInputByAssetID`, `PhotoAdjustments.lut`, the `LUTs/` folder), migration and offline behavior.
- [ ] `ARCHITECTURE.md`: replace the "Core Image-backed `AVVideoComposition`" paragraph with the compositor pipeline, and update the `ColorGrading.swift` description (no 48-point cube).
- [ ] `PERFORMANCE_TARGETS.md`: the G1/G7/G9 targets and measured results. `TESTING_STRATEGY.md`: the new env vars and opt-in suites. `ROADMAP.md`: tick V0.2 LUT import once G3 passes; add V0.3 items for the 10-bit compositor, V-Log color management, scopes and frame-exact timing. `CURRENT_STATUS.md`.

---

## Acceptance scenarios

1. **V-Log auto-detection.** Import `P1107210.MOV`. Its source color shows "V-Log / V-Gamut (camera metadata), 10-bit 4:2:2, full range". With OCIO available, it plays as normal Rec.709 without user action. Choosing *None* shows the flat log image. *Failure:* metadata missing or malformed → descriptor from tags (Rec.709), with an inline hint "Set source color if this is log footage".
2. **LUT workflow.** Import Panasonic's LUT and assign it as the source color for all selected V-Log media items. Source color belongs to the media item, so every clip cut from it follows. Intensity 50% blends. Close and reopen: the LUT is still applied from the shoot's `LUTs/` folder. *Failure:* the user deletes `LUTs/` → a warning badge on affected clips; they play ungraded-log; the project still opens.
3. **Mixed timeline.** Place `P1107172` (8-bit Rec.709) between two V-Log clips and play across both cuts. No flash, no size change, and each cut lands on the chosen frame.
4. **Sky grade.** On `P1107210`, Blue saturation +60 and luminance −40 with the 10-bit pipeline shows no visible contour bands on a reference display. The waveform shows no comb gaps.
5. **Scopes.** Open the scopes while playing the 1080p proxy. Playback stays realtime. The waveform and vectorscope update at ≥ 10 Hz and freeze on the paused frame.
6. **Export.** Export the three-clip timeline as ProRes 422 HQ UHD. The file is 10-bit 4:2:2, tagged Rec.709, with frame count = sum of clip frames. It is built from originals, never proxies, and the source files are untouched.
7. **Old project.** Opening a schema-10 project with seconds-based clips converts it to frames. It plays the same cut, and saving writes schema 11. An offline clip keeps its timing until relinked.

## Test strategy

| Layer | What | Where |
| --- | --- | --- |
| Pure unit (no GPU) | `FrameRate` math, migration, the `.cube` parser, the Panasonic XML parser, the HSL Double reference, the V-Log Double oracle | `FrameTimeTests`, `ProjectMigration11Tests`, `CubeLUTTests`, `SourceColorTests`, `ColorGradingTests` |
| GPU unit (Metal device required; reported as skipped otherwise) | Decode kernel, HSL kernel vs reference, tetrahedral LUT, OCIO shaders vs golden data, scope bins | `MetalColorKernelTests`, `OCIOShaderTests`, `ScopeRendererTests` |
| Integration (synthetic movies) | Compositor through `AVAssetReaderVideoCompositionOutput`; frame-numbered fixture for exactness; 10-bit ramp for level counts; mixed formats; cancellation; export | `TimelineVideoCompositorTests`, `TimelineFrameExactTests`, `TimelineExporterTests`, existing proxy suites |
| Real footage (opt-in env vars, read-only) | G1–G9 below | `RealVideoColorTests` with `--no-parallel` |
| Runtime/UI (human on the target M1) | Source-color picker, LUT import, scopes panel, export sheet, visual review | Checklist in this plan's QA gate |

Rules: red tests first for the drift bug (Task 1) and the banding bug (Task 5). Synthetic tests never stand in for G-gates. Every opt-in suite reports executed and skipped counts. Fixtures are generated into temporary directories. No test writes inside `/Volumes/ExSSD1/Pictures`. `RealVideoColorTests` asserts that each source file's size and mtime are unchanged after the run.

## Real-footage gates (target 8 GB M1, release build, app otherwise idle)

| Gate | Pass criterion | Method |
| --- | --- | --- |
| **G1 Throughput** | Export of 60 s of `PME_VIDEO_SAMPLE` through the compositor (neutral grade + V-Log input transform) runs at ≥ 38 fps (≥ 85% of the 45 fps decode ceiling). 1080p proxy preview with grade + LUT + HSL + scopes plays 60 s with 0 dropped frames (`AVPlayerItem.accessLog().droppedVideoFrames`) and GPU time ≤ 12 ms per frame. | `RealVideoColorTests.exportThroughput`, signposts |
| **G2 Code-value fidelity** | With `.none` input transform, compositor-decoded R'G'B' on 64 pixel positions × 3 frames of `PME_VLOG_SHORT` match ffmpeg's `gbrp16le` decode (`in_range=pc`, BT.709 matrix) within 1/1023 for originals and 2/1023 for proxies. Proxy luma never pins at 64 or 940 where the original does not. | Reference frames made by ffmpeg into `PME_VIDEO_OUTPUT_DIR` |
| **G3 LUT agreement** | Panasonic V709 LUT output vs `ffmpeg … lut3d=file=…:interp=tetrahedral` on the same frames: 99.9th percentile ≤ 2/1023, max ≤ 4/1023 per channel. | Same harness |
| **G4 OCIO agreement** | The Metal transforms on real frames vs PyOpenColorIO CPU on the same pixels (script mode `--reference-frames`): ≤ 1e-3 abs (encoded) and ≤ 0.2% relative (linear above 1). | Script output + test |
| **G5 Banding** | The sky region of `PME_VLOG_SKY` (crop recorded in the test) under scenario 4's grade: ≥ 95% of the distinct output levels the analytic Double reference produces; no adjacent-pixel step > 3/1023 attributable to grading. The owner's visual review on the M1 display finds no contours. | Test + human review (recorded with a screenshot in the evidence) |
| **G6 Frame exactness** | Trim `PME_VIDEO_SAMPLE` to source frames 33 000–33 239 at timeline frame 0 and export as ProRes 422 HQ. For each exported frame k (spot-check every 10th plus the first and last), compare its luma against source frames N−2…N+2 (N = 33 000 + k), decoded with zero-tolerance `AVAssetImageGenerator`. Best PSNR must be at N, by ≥ 3 dB over the neighbors, and ≥ 45 dB. Exported frame count is exactly 240. An ffmpeg `select=eq(n\,33000)` extraction agrees on the first frame. | `RealVideoColorTests.frameExactLateInLongClip` |
| **G7 Memory** | Peak footprint over idle, summed over the app **and `VTDecoderXPCService`** (decoding is out of process; Task 0 measured 252 MB for the decoder at UHD `xf22`): ≤ +600 MB during UHD export, ≤ +350 MB during 1080p proxy playback with scopes. No growth > 20 MB across 10 consecutive 60 s playbacks. Swap does not increase during the run. | `footprint`/`profile-video.sh`, `vm_stat` before/after |
| **G8 Visual** | The owner compares LUT vs OCIO on `P1107210` and `P1107158` (skin, sky, highlights) and records the default-view decision (Decision 3). | Human, screenshots in evidence |
| **G9 Scopes** | On `PME_VLOG_SHORT` with *None*: waveform black near code 128 and the V-Log grey card (if present) near 433. Scope update ≥ 10 Hz during playback, GPU cost ≤ 2 ms per update at 1080p. | Test + signposts |

## Original-media and project-data safety

- Originals are opened read-only through AVFoundation. LUT import copies the file. Exports and proxies only write new files and publish them atomically.
- Schema 11 is a deliberate version bump with a tested migration from 10. Older app builds will refuse schema-11 files (the existing `unsupportedSchema` guard), which the release notes must say. Unconverted offline clips keep their original seconds, so nothing is rounded twice.
- The proxy cache-key version bump regenerates proxies. It does not delete user data.

## Risks

| Risk | Mitigation |
| --- | --- |
| A custom compositor cannot receive `xf22`, or AVFoundation converts internally at BGRA-like cost | Task 0 measures before building; escalation path defined |
| AVFoundation silently range-remaps full-range V-Log | Explicit range handling, G2 code-value gate |
| Core Image in half float still rounds or clamps somewhere | Ramp level-count tests at each stage; HSL and LUT moved to our kernel |
| OCIO MSL output needs a newer MSL or features (textures, samplers) | Task 0 compile check; manifest-driven bindings |
| 4K half-float buffers exhaust 8 GB | YCbCr in and out, pool cap 3, G7 |
| Schema-11 migration loses timing for offline media | Keep legacy seconds until relink; migration tests |
| Scope work steals GPU from playback | Visible-only, every other frame, downsampled, single-slot mailbox; G1 includes scopes |

## QA gate

| Gate | Result | Evidence or next action |
| --- | --- | --- |
| Build/static | PENDING | `swift build` with the CLT SDK workaround |
| Unit | PENDING | `run-tests` per suite above |
| Integration | PENDING | Compositor, frame-exact, exporter, proxy suites |
| Runtime/UI | PENDING | Scenarios 1–7 on the target M1 |
| Real media/quality | PENDING | G2, G3, G4, G5, G6, G8, G9 |
| Target-hardware performance | PENDING | G1, G7 |

## Suggested order and parallelism

Task 0 → (Task 1 ∥ Task 2 ∥ Task 6 parser/library) → Task 3 → Task 4 → (Task 5 ∥ Task 6 rendering ∥ Task 7 ∥ Task 9 script) → Task 8 → Task 11 → Task 12. Task 1 touches `EditorModels`/`EditorStore` timeline code. Task 2 touches `ProxyGenerator`/`EditorModels` media fields. Keep one writer on `EditorModels.swift` at a time (do Task 1's model change first, then rebase Task 2).

## Closeout

To fill in at the end: user outcome, changed contracts (schema 11, compositor, LUT library), limitations (no HDR, no runtime OCIO configs, single sequence frame rate), and the next roadmap item (V0.3 titles/transitions, or Phase B2 if custom configs are needed). Follow-up outside this plan: make `scripts/test.sh` detect a CLT-only toolchain and apply the SDK and testing-plugin workaround.

## Plan review (2026-10-16, self-review against code, SDK headers and real footage)

Checked against `TimelineCompositionService.swift`, `ColorGrading.swift`, `MediaColorRenderer.swift`, `EditorModels.swift` (schema 10), `ProxyGenerator.swift`, the macOS 26.5 SDK `AVVideoCompositing.h`/`AVVideoComposition.h`/`CVPixelBuffer.h`, OCIO `PanasonicCameras.cpp` and `OpenColorTypes.h`, and `ffprobe`/`signalstats` on the `110_PANA` clips.

Corrections made during the review:

1. **Unlisted source formats.** The engine converts any source whose pixel format is not listed, in both format and color space. The format list now covers 8-bit and 10-bit, 4:2:0 and 4:2:2, and video and full range. `canConformColorOfSourceFrames` is added (Task 4).
2. **MSB-aligned samples.** 10-bit `x422`/`xf22` samples sit in the upper 10 bits of each 16-bit word. The decode math now says so (Task 3).
3. **Export encode.** Export needs our own RGB→Y'CbCr encode, and ProRes keeps codes 4–1019. Added `encodeYCbCr` and a round-trip test (Task 3).
4. **Rec.709 regression.** Rec.709 clips could change look when Core Image's own 709 linearization is replaced. Added a golden-output regression test against the old handler before removing it (Task 4).
5. **G6 measurement.** G6 relied on hash equality, which a lossy ProRes re-encode cannot meet. It now picks the best match among neighboring frames by PSNR (G6).

Open items that need an owner or measurement (not plan defects): Decisions 1–3; Task 0's outcome, which can reshape Tasks 3–4 and 8; whether `x422` proxy reads of full-range V-Log rescale or clip (Task 0 range check).
