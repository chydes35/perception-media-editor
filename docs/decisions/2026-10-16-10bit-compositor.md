# 10-bit compositor formats and OCIO shaders — October 16, 2026

Plan: [video-10bit-color-pipeline.md](../../plans/active/video-10bit-color-pipeline.md), Task 0.
Hardware: the target 8 GB M1 MacBook Air, macOS 26, Command Line Tools only, release (`-O`) probes.
Footage (read-only): `/Volumes/ExSSD1/Pictures/110_PANA`. `P1107158.MOV` (3 s), `P1107210.MOV` (11.5 s) and `P1107157.MOV` (1386 s) are V-Log, H.264 High 4:2:2 10-bit, full range, tagged BT.709. `P1107172.MOV` is 8-bit 4:2:0 video range, STANDARD gamma.
Probes: [`scripts/video-probes/`](../../scripts/video-probes). Build them with `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swiftc -O -swift-version 5 <file>.swift`.

## Measurements

**Compositor source formats** (`probe.swift`). A minimal `AVVideoCompositing` class runs through `AVAssetReaderVideoCompositionOutput` for 60 s (1 439 frames) of `P1107157`:

| `sourcePixelBufferAttributes` | Received | fps | IOSurface | `VTDecoderXPCService` footprint |
| --- | --- | --- | --- | --- |
| `[xf22, x422, 420v, 420f]` | `xf22` | 47.3 | 1439/1439 | — |
| `xf22` | `xf22` | 47.3 | yes | **252 MB** |
| `x422` | `x422` | 47.1 | yes | — |
| `64RGBAHalf` | `RGhA` | 47.2 | yes | **406 MB** |
| `32BGRA` | `BGRA` | 47.6 | yes | — |
| `xf22` + wrap planes as `MTLTexture` via `CVMetalTextureCache` | `xf22` | 45.3 | yes | — |

- Every format runs at the decode limit (about 47 fps). The 12 fps BGRA figure from the proxy evaluation applies to `AVAssetReaderTrackOutput`, not to a compositor.
- The probe process stays at about 25 MB. The decoder runs out of process, so memory gates must also measure `VTDecoderXPCService`.
- With the list `[xf22, x422, 420v, 420f]`, the 8-bit file arrives as `420v` (81 fps) and V-Log arrives as `xf22`. AVFoundation picks each source's native format from the list.

**Code values** (`cmp.py`). Frames 0, 36 and 71 of `P1107158`, 64 grid positions each, are compared against `ffmpeg … -pix_fmt yuv422p10le` raw output:

- `xf22`: Y', Cb and Cr are **bit-exact** (difference 0 at all 192 samples).
- `x422`: Y' is **+64 exactly**, and Cb/Cr are unchanged. This is not a full→video range conversion, which would be `64 + Y'·876/1023`.
- `64RGBAHalf`: the values are gamma-encoded R'G'B' with full-range interpretation. For a grey pixel, Y' 398 gives 0.392/0.388/0.386.

**Existing proxy recipe** (`proxyprobe.swift` + `cmpproxy.py`). ProRes 422 Proxy written from `x422` reads, and from `xf22` reads, at full size, frame 0:

- Both store **luma = original + 64** (fit 0.9989·Y + 64.5) and are tagged `tv`, BT.709.
- Read back as `xf22` they round-trip to the original within ProRes error. Read as RGB, which is what AVPlayer and Core Image do, the proxy is **1023/876 ≈ 17% brighter** (grey 0.392 → 0.460). Original codes above 876 clip at display white, and V-Log reaches 931 on this card.
- This means `feat/video-proxies` currently previews V-Log clips brighter than their export. Every full-range source is affected.

**Output formats:**

- `x422` compositor output goes into `AVAssetWriter` as ProRes 422 HQ (`yuv422p10le`, `tv`, BT.709) and as HEVC Main10 (`yuv420p10le`). Both run at 47.5 fps for 240 of 240 frames of `P1107210`, with no extra conversion.
- `AVPlayer` with `AVPlayerItemVideoOutput` plays the 4K original through the compositor in real time (134 frames in 5.4 s), with both `64RGBAHalf` and `x422` output.

**OCIO** (`ocio_gen.py`, `ociometal.swift`). PyPI `opencolorio==2.5.2` plus `numpy` were installed in an isolated venv:

- `ocio://studio-config-latest` resolves to `studio-config-v4.0.0_aces-v2.0_ocio-v2.5`. It contains `V-Log V-Gamut` and the **ACES 2.0** view `ACES 2.0 - SDR 100 nits (Rec.709)` on `Rec.1886 Rec.709 - Display`. It has no ACES 1.3 view.
- `GPU_LANGUAGE_MSL_2_0` text compiles at runtime with `makeLibrary(source:)` and `languageVersion = .version2_4`. A cold compile takes 408 ms; later ones take 23–68 ms.
- V-Log→linear Rec.709 and the built-in `PANASONIC_VLOG-VGAMUT_to_ACES2065-1` need no textures. The ACES 2.0 output needs two `texture1d` tables of 363 entries (one red channel, one RGB) plus samplers.
- GPU vs OCIO CPU on 4 096 seeded inputs: maximum absolute error 5.8e-4 (V-Log→linear 709, outputs up to about 120), 3.1e-4 (built-in to AP0) and 5.4e-6 (ACES 2.0 output). Code 433/1023 maps to linear 0.1799.

## Decision

1. The compositor requests `[xf22, x422, 420v, 420f]` (adding `xf20`/`x420` when 10-bit 4:2:0 sources appear) with Metal compatibility, and decodes Y'CbCr itself. Do not request `64RGBAHalf`: it is no faster and costs about 150 MB more in the decoder process at UHD. Never request 32BGRA, because it is 8-bit, not because of speed.
2. Preview output is `64RGBAHalf`. Export output is `x422`, encoded by our own kernel, into ProRes 422 HQ or HEVC Main10.
3. Range is a property we track explicitly. A buffer delivered as `x422` from a full-range source carries luma + 64, so never request `x422` for full-range sources.
4. **Proxy fix (Task 2, raised in priority).** Read full-range sources as `xf22` and convert to correctly scaled video range ourselves (Y' = 64 + Y'·876/1023, C = 512 + (C − 512)·896/1023, rounded). Append those frames through a pixel-buffer adaptor tagged video range. Bump the proxy cache-key version so existing, too-bright proxies regenerate. Until then, treat existing V-Log proxies as known-wrong.
5. Phase B uses the OCIO 2.5 studio config with **ACES 2.0 SDR 100 nits (Rec.709)** as the display view, replacing the ACES 1.3 view in the plan. The generator also exports texture tables. `scripts/ocio/requirements.txt` pins `opencolorio==2.5.2` and `numpy`. Shaders compile once, off the main actor, at first video use.

## Alternatives considered

- **`64RGBAHalf` sources:** simpler, since AVFoundation does the YCbCr→RGB step, but it costs more decoder memory and leaves range handling to AVFoundation.
- **Keeping the AVFoundation proxy conversion:** it round-trips inside our compositor, but AVPlayer, Core Image, the source viewer and any other app see a brighter, clipped proxy.
- **Linking OCIO:** see Task 10. Generated shaders already meet the accuracy target.

## Proxy fix result (same day)

`ProxyGenerator` now reads full-range sources as `xf22`, scaled to proxy size by the reader. The probe found that the reader's scaled `x422` path is worse than the unscaled one: luma + 64 **and** clipped at 940. `VTPixelTransferSession` converts to `x422`, and the probe confirmed its scaling (mean 430.7 against an expected 430.7). The frames are appended through a pixel-buffer adaptor. The proxy key gained a format version (2).

- Synthetic full-range HEVC 4:2:2 fixture: proxy RGB within 4/1023 of the original (`fullRangeSourceProxyShowsTheOriginalsColors`). It failed by 146 levels before the fix.
- Real `P1107158`: cell-mean difference 1.8/1023, against 104.5 with the old generator.
- Throughput on the 10 s UHD trim: 72.0 fps debug and 79.6 fps release, up from 68.5 debug.

## Task 3 result: video color kernels

`MetalPipelineCache`, `MetalShaderSources` and `VideoColorKernels` convert 12 bi-planar Y'CbCr formats (8/10-bit × 4:2:0/4:2:2/4:4:4 × video/full range) to unclamped `rgba16Float`, encode to `x422`, and fit a frame to a render size. Notes:

- **Range comes from the buffer's pixel format**, not from a descriptor, because Task 0 showed that an `x422` buffer from a full-range file is shifted by 64 and an `xf22` one is exact. The matrix comes from the caller (the descriptor, or Rec. 709 when unlabeled).
- **Tolerance is 0.3/1023, not the plan's 0.25.** Half-float storage rounds values in [0.5, 1) to a multiple of 2^-11, which alone costs up to 0.25 of a 10-bit step. A real frame measured 0.249.
- **Not an actor.** The compositor calls from a synchronous request queue, so `MetalPipelineCache` is a class with a lock. The `CIContext` the plan listed for it is deferred to Task 4, which is its first user.
- **GPU cost:** decoding a 3840×2160 `xf22` frame takes a median 1.87 ms on the M1 (release build, 10 runs), against 21 ms of frame time at 47 fps.
- **Fit** is bilinear, which suits fitting a frame to the render size (1:1 up to about 2×); it is not a high-quality large reduction.
- Chroma siting is left, as in the camera files (4:2:0 also half a row down). Reading the siting from the format description is not done, because every source seen so far is `Left`.

## Task 4 result: the custom compositor

`TimelineVideoCompositor` (with `PreviewVideoCompositor` and `ExportVideoCompositor`) replaces the `AVVideoComposition(applyingCIFiltersWithHandler:)` path. Architecture is in [ARCHITECTURE.md](../ARCHITECTURE.md#custom-compositor). Findings:

- **Core Image must be given frames tagged `CoreMedia709`.** My first graded frame, tagged plain ITU-R 709, sat 10.2 of 255 levels (mean) from the old handler's output; working-space variants (extended linear sRGB, P3, none) did not help. AVFoundation uses Apple's video Rec. 709 (gamma about 1.96) for 709-tagged sources, and with that tag the mean is 0.3 (max 16) on a frame that uses every stage of the color chain. A neutral frame matches AVFoundation's own decode at a mean of 0.07. The golden frames from the old path are in `Tests/Fixtures/video`.
- **Rotation moved into this task.** A custom compositor receives stored frames, so the fit kernel applies each clip's `preferredTransform`; without it a portrait phone clip would have played sideways. Verified against AVFoundation's own rotation.
- **Gaps:** a black instruction. AVFoundation delivers an empty edit as one frame lasting the whole gap, so the exporter (Task 8) must expand it if it wants constant frame rate.
- **A bug in the proxy generator surfaced:** proxies were written at the default timescale of 600, rounding frame times (frame 150 started 0.4 ms late), so a player asking for that frame's exact time showed frame 149. Fixed by writing at the source's timescale; cache key version 3.
- **Throughput and memory** are in [PERFORMANCE_TARGETS.md](../PERFORMANCE_TARGETS.md#video-compositor-branch-plan10bit-vlog-color): neutral 4K runs at 75–79 fps, graded 4K at 21–36 fps, a graded 1080p proxy at 83–136 fps. Graded 4K uses about 770–860 MB over idle, over G7's 600 MB budget.
- **Not covered:** the cancel path (the seek storm never made AVFoundation cancel), on-screen playback in the app (only reader, image generator and player-output paths were driven), and the source viewer, which has no input transform to show until Tasks 6 and 9.

## Task 5 result: HSL and curves at 10-bit precision

- **The HSL cube was the defect, not banding steps.** In a half-float pipeline the trilinear 48³ cube is continuous, so it never made steps between adjacent pixels; its kinks (0.5 of 1023) were no larger than half-float rounding. What it did was miss the exact HSL function: by up to 37 of 1023 levels (mean 1.6) on random colors with strong settings, mostly near the hue wrap and the grey threshold, and by 4.1 on a graded sky gradient.
- **Replaced by an exact per-pixel color kernel** (`HSLColorKernel`), the same math as `ColorGrading.applyHSL`. Measured against the Double reference on the GPU: sky 0.0005, random colors 0.001 of 1023. Core Image fuses it into one pass, so nothing is rounded to half float in between. It covers photos and video, which both go through `MediaColorRenderer`.
- **Why a color kernel, not the planned processor kernel or Metal compute.** A `CIImageProcessorKernel` runs on Core Image's own command buffer. In the compositor, the decode is encoded on our command buffer just before grading, so the processor read the frame before it was written (black or wrong frames). A color kernel stays inside Core Image's graph. It is written in the deprecated Core Image Kernel Language, compiled at run time (no `metal` compiler here); `RetouchRenderer` already does the same. If a future macOS drops it, the 48³ cube fallback takes over.
- **The cube fallback stays at 48³.** On 150 solid colors through Core Image's cube filter, 48³ measured a worst of 4.5 of 1023 and 64³ measured 8.8, so the plan's "raise to 64" would have made it worse.
- **Curves:** 1024 samples instead of 256 bring a strong S curve from 0.43 to 0.25 of 1023 (the half-float floor).
- **Look change:** a graded frame with strong HSL now differs from the old CIFilter path by a mean of 1.5 of 255, which is the old cube's error. Without HSL the new pipeline still matches the old one (mean 0.30; new golden `old-ci-path-graded-no-hsl.png`, captured from commit 28be3c0).
- **Real footage (G5 precision part):** the top 240 rows of `P1107210` (UHD V-Log, trees and an overcast sky), decoded on the GPU and graded with the sky HSL setting, are within 0.50 of 1023 of the Double reference (half-float output), keeping all 434 of 434 distinct blue levels. Only 1.1% of the pixels move by more than a level, because overcast V-Log carries almost no chroma, so this is a weak sky test. **G5's visual part stays open:** it needs a clip with a clear blue sky and the owner's look at the M1 display.
- **Speed:** with the kernel, graded 4K V-Log runs at 24.7 fps and a graded 1080p proxy at 96.5 fps (release, M1), inside the ranges measured with the cube (21–36 and 83–136), so no measurable cost. Graded 4K peaked at 903 MB (876 with the cube).
- **Test-harness note (corrected):** some Task 5 test images rendered as zeros. The cause was my test code, not Core Image: `values.flatMap { [$0.x, $0.y, $0.z, 1] }` resolves to the `flatMap` that returns `[[Any]]`, so the bitmaps held array pointers instead of pixels. Core Image renders RGBAf and RGBAh bitmaps of every size tried (up to 4096×4096) correctly. The 48³-versus-64³ cube comparison is unaffected; it used solid-color images.

## Verification still owed

Task 0 measures feasibility only. G1–G9 in the plan remain open. The `VTDecoderXPCService` footprints are single samples taken mid-run. G7 must repeat them as peaks over whole runs.
