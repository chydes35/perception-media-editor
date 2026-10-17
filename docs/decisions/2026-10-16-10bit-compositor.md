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

## Task 6 result: `.cube` LUTs

- **Parser and library:** 3D (2–65) and 1D (2–65 536) tables, domains, Resolve's input-range form, comments, CRLF, scientific notation; readable rejections for 12 kinds of bad file and for files over 64 MB. Imports go into a content-addressed library and, on save, into `LUTs/` next to the project; every loaded file is checked against its hash. Shaper LUTs (1D plus 3D in one file) are rejected with a message.
- **One kernel for every use.** A Core Image kernel (kernel language, like HSL) reads the table from a small uncolor-managed image and interpolates tetrahedrally. The planned Metal shader was not needed: after Task 5, a Core Image kernel is the way to stay in order on the compositor's command buffer. The same kernel serves creative LUTs on photos and clips (sRGB-encoded, after the global adjustments) and a clip's source color in the compositor (on untagged decoded code values, then treated as Core Media's Rec. 709).
- **Accuracy:** an identity 33³ LUT changes colors by at most 0.5 of 1023; a 17³ channel-swap-and-gamma table matches its tetrahedral reference to float precision and the function itself within the interpolation bound (1.0 of 1023); lattice points are exact; intensity 0 is bit-identical to no LUT; a 4100-entry 1D table spanning two table rows matches its reference. In the compositor, a source-color LUT on 10-bit code values matches the reference within 0.47 of 1023.
- **Gate G3: PASS.** Panasonic's own `Vlog_to_V709_forV35_ver100.cube` (33³, found with DaVinci Resolve at `/Library/Application Support/Blackmagic Design/DaVinci Resolve/LUT/Panasonic/V-Log to V-709.cube`) on frame 0 of `P1107158`, through the compositor, against ffmpeg 8.1.2's `lut3d=interp=tetrahedral` on the same frame: mean 0.71, 99.9th percentile 1.52, max 1.73 of 1023 (limits 2 and 4), over the 4.1 million even-column pixels. Two findings on the way:
  - ffmpeg's `lut3d` equals a straightforward tetrahedral evaluation exactly, and ours is within 1.3 of 1023 of it on the same input.
  - The first comparison failed (99.9th percentile 28.8, max 66) entirely because of the decoders. swscale interpolates 4:2:2 chroma even on the columns where the file's left-sited chroma sample sits; it differed from the exact sample by up to 34 of 1023 on saturated edges. The reference script (`scripts/video-probes/ffmpeg-lut-reference.sh`) now asks for left-sited, uninterpolated chroma, and ffmpeg's decode then matches the exact sample within 0.88.
- **Speed:** Panasonic's LUT as source color on 4K V-Log runs at 78.7 fps (preview) and 79.2 fps (export) on the M1, the same as without it. That is G1's case (V-Log input transform, at least 38 fps), measured here on a 10 s trim rather than G1's 60 s.
- **Not verified:** the pickers and intensity sliders in the running app (Photo → LUT, video inspector → Source color and clip LUT); G3 on more than one frame; multi-select of media items for source color (the video bin selects one item at a time).

## Task 7 result: waveform and vectorscope

- **Design.** While the scope panel is open, preview requests (never export) encode a 4×4-tap box downsample of the frame into a 512-wide `rgba16Float` capture on the compositor's own command buffer; the completion handler publishes it. `ScopeRenderer` has its own command queue and accumulates a 512 × 1024 waveform (luma, or an RGB parade in thirds) and a 512 × 512 BT.709 Cb/Cr vectorscope with `atomic_uint`, then draws both into `bgra8Unorm` images with log gain, guides at codes 0, 64, 512, 940 and 1023, 75% and 100% bar boxes and a skin-tone line. The panel shows them as layer contents. "Output" measures the graded picture; "Source" measures the decoded code values before the input LUT and grade.
- **Deviations from the plan.** The tap keeps a ring of three reused textures (the latest is published) rather than a single slot: a capture can then be written while the previous one is still being analyzed. The images are `CGImage`s in a layer rather than an `MTKView`; at 12–15 updates a second that costs a 1 MB readback per update and keeps the view trivial. `ScopeRenderer` is a locked class rather than an actor, because its calls block on the GPU.
- **Throttling by timeline time.** The first throttle used wall-clock time (at most every 1/15 s) and gave 7.2–7.8 updates a second on real playback. Players render in bursts (captures were alternately 80 and 210 ms apart), so most frames in a burst were skipped. Captures are now chosen by composition time, at least 1/20 s apart in the timeline (every second frame at 24–30 fps), with wall-clock time as a fallback so a seek or step after a pause is always captured. The analysis worker keeps only the newest waiting capture.
- **Gate G9: PASS for rate and cost, black level NOT VERIFIED.** On `P1107158` (UHD V-Log, no input transform), pulled through the compositor at the clip's own 24 fps: 14.6 updates a second; analysis 0.67 ms GPU (median) plus the downsample 0.43 ms at 1080p, 1.1 ms in all (limit 2 ms). At 4K render size the downsample is 1.46 ms, so 4K originals cost about 2.1 ms per update. The first frame's waveform agrees with its luma plane read as `xf22`: mean code 428.3 for both (ffmpeg `signalstats` YAVG 428.29), 10th percentile 218 against 216 and 90th 593 against 594. This shot has no true black (its darkest pixels are noise at 96–103 in ffmpeg), so "black near code 128" cannot be checked on it; a lens-cap or deep-shadow V-Log clip is needed. It has no grey card either.
- **Known limit.** Frames are captured when rendered, and AVPlayer renders ahead of display, so during playback the scopes can lead the picture by the player's buffer (about 0.1–0.2 s). When paused, they match the frame shown.
- **Not verified:** the scope panel in the running app (toggle, mode and source pickers, live updates during AVPlayer playback, the paused-frame case).

## Task 8 result: 10-bit timeline export

- **Design.** `TimelineExporter` (an actor) builds the composition at export quality with no proxy input at all, so it can only read camera originals. Frames come through `AVAssetReaderVideoCompositionOutput` with the same compositor and instructions as playback, as video-range 10-bit 4:2:2, at the chosen size (timeline size, UHD or 1080p, fitted with even sides). The composition's mixed audio goes out as 24-bit LPCM with ProRes or 256 kb/s AAC with HEVC. The writer makes ProRes 422 HQ or HEVC Main10, both tagged Rec. 709, into `<name>.partial.mov` beside the destination, renamed into place only when complete. The destination is checked against every original before and after rendering. A disk guard (estimated size plus 1 GB) runs before anything is written. Cancel stops at the next sample and removes the partial file. One export runs at a time, and the proxy queue pauses (its running job goes back to the front of the queue) until the export ends. The timeline toolbar has an Export menu (format, size, Export Timeline…) and shows progress with a cancel button.
- **Two fixes found by tests.** The composition always has an audio track, and an audio-mix output over an empty one failed the whole read (-12710), so only tracks with segments are read. Cancelling the reader from the cancellation handler while a pump queue was inside `copyNextSampleBuffer` crashed in MediaToolbox (about one run in three); cancel now only sets a flag, and the reader is cancelled after both pumps have stopped.
- **10-bit:** on a full 0…1023 ramp, ProRes 422 HQ keeps 872 and HEVC Main10 863 distinct luma codes. The plan asked for at least 1 000, which video range cannot hold: it has 877 codes (64…940). The test asks for at least 860 (ProRes) and 700 (HEVC).
- **Gate G6 through export: PASS.** Source frames 33 000–33 239 of `P1107157`, exported as ProRes 422 HQ: exactly 240 frames; every checked frame (every tenth plus the last) best matches its own source frame, with a worst PSNR of 63.1 dB and at least 20.4 dB over any neighbor. ffmpeg's frame 33 000 (by decode index) matches exported frame 0 at 64.2 dB. The comparison uses raw 10-bit luma codes (the export as `x422`, the original as `xf22` mapped to video range). Comparing AVFoundation's RGB images instead gave only about 33 dB for every frame, because AVFoundation's RGB of the full-range original and of the video-range export disagree. The codes themselves agree: frame 33 000 averages 452.0 full range, which is 451.1 in video range, and the export averages 451.1.
- **Gate G1: FAIL on this Mac.** 60 s of UHD V-Log through Panasonic's V-Log to V-709 LUT, at UHD: ProRes 422 HQ 8.8 fps, HEVC Main10 34.4 fps (target 38). The read side alone ran at 79 fps in Task 6, so the encoders set the pace. The M1 has no ProRes engine (the M1 Pro and Max do), so ProRes is encoded in software. HEVC uses the hardware encoder and is 10% short.
- **Gate G7 (export): FAIL.** `scripts/profile-video.sh`, the same 60 s case: peak about 1.5 GB over idle (the app about 1.0 GB, `VTDecoderXPCService` about 540 MB) for either codec; the limit is 600 MB. 10 700–13 300 pages were swapped out during the run. The read side alone peaked near 470 MB in Task 6, so the writer and the frames waiting for it add about half a gigabyte. This belongs with the open graded-4K memory work (Task 11).
- **Not verified:** the Export menu and progress in the running app; export of a graded timeline at UHD (only neutral plus the input LUT was measured).

## Task 9 result: OpenColorIO shaders (Phase B1)

- **Generator.** `scripts/ocio/generate-shaders.py` runs in a throwaway venv (`pip install --require-hashes -r scripts/ocio/requirements.txt`: `opencolorio==2.5.2`, `numpy==2.5.4`, hashes for the macOS arm64 CPython 3.14 wheels). It resolves `ocio://studio-config-latest` to `studio-config-v4.0.0_aces-v2.0_ocio-v2.5` and writes `Sources/PerceptionEditor/OCIOGeneratedShaders.swift` (MSL 2.0 text, lookup tables, OCIO version, config name and the script's SHA-256) and `Tests/Fixtures/ocio-golden.json`. Two transforms: `vlog_vgamut_to_lin_rec709` (the built-in `PANASONIC_VLOG-VGAMUT_to_ACES2065-1`, then ACES2065-1 to linear Rec. 709, unclamped) and `lin_rec709_to_rec1886_aces20` (view `ACES 2.0 - SDR 100 nits (Rec.709)` on `Rec.1886 Rec.709 - Display`, with its two 363-entry tables). The optional ACES 1.3 transform was not generated; it waits on the owner's G8 review.
- **Runtime.** `OCIOColorKernels` compiles the OCIO text plus three wrapper kernels (`ocioInput`, `ocioOutput`, and both in one pass) into a Metal library of its own, so a failure to compile cannot break the other video kernels. The composition then warns and V-Log shows as recorded. Clips with nothing to grade take the one-pass kernel. Graded clips go input transform → Core Image in scene-linear Rec. 709 (extended linear sRGB, Core Image's working space, so nothing is converted) → ACES output. Tables stay 32-bit float and are sampled with a nearest sampler, because OCIO's code computes the texel centers itself.
- **Source color.** `ColorInputTransform.aces` ("V-Log → Rec. 709 (ACES 2.0)") joins the picker. **Automatic now means ACES for footage detected as V-Log.** This follows Decision 3's recommendation and acceptance scenario 1. The owner's G8 comparison against Panasonic's LUT is still open, and a one-line change in `resolvedOCIOInputs()` reverts it. Choosing ACES by hand applies the V-Log transform to any clip, which covers log footage whose camera metadata was lost.
- **Deviations from the plan.** Tables are float literals in the generated Swift file, not `Resources/OCIO/*.bin` with a manifest. That way Package.swift needs no resources and the tables stay in float32. The golden data lives in `Tests/Fixtures/`, outside the test target, so SwiftPM needs no resource declaration. It includes a third set (both transforms composed) for the one-pass kernel. Its inputs are exact in half float. It comes from OCIO's `OPTIMIZATION_LOSSLESS` CPU processor, because the default processor's fast pow is about 1e-4 off. The "CI hash check" is a unit test (`OCIOGeneratedSourceTests`) that runs with the rest of the suite in `test.yml`. The BSD-3 notice is `Resources/ThirdPartyNotices/OpenColorIO-BSD-3.txt`, and `build-app.sh` copies it into the bundle beside `ModelNotices`. The app has no About window to list it in.
- **Accuracy.** All 4 096 golden samples per transform agree with OCIO's CPU processor within 1e-3 absolute (0.2% above 1), for each transform and for the one-pass kernel. An independent Double V-Log oracle (Panasonic's curve, V-Gamut→Rec. 709 from the primaries) agrees with OCIO within 1e-4 (2.2e-5 measured). Code 433/1023 gives linear 0.180. Running the two passes through a half-float intermediate departs from the one-pass result by up to 3e-3, where gamut compression magnifies the rounding. The compositor test therefore checks the one-pass kernel against its own reference, and the graded path is checked separately: +1 EV in the compositor equals the output transform of exactly twice the linear values.
- **Gate G4: PASS.** On 6 912 positions over frames 0, 36 and 71 of `P1107158`, decoded by the compositor's kernel, the Metal transforms against PyOpenColorIO (`--reference-frames`) reach 0.49 of the limit for linear and 0.49 for the display output. That is about one half-float step. The source's size and mtime are unchanged.
- **Speed (release, M1, 10 s of 4K V-Log from `P1107157`).** Neutral: 78.6 fps without ACES and 35.7 with it (preview), 35.9 fps for export frames. Graded: 25.1 fps without ACES and 15.9 with it. The 1080p proxy, graded, runs at 94.6 fps without ACES and 49–50 fps with it. The ACES 2.0 output transform costs about 15 ms per 4K frame, mostly the JMh gamut compression and its table search. Through ACES, G1's 38 fps export target is missed at 4K, and graded 4K originals cannot play in real time. Proxy playback is fine. If Task 11 needs the time back, the next step is to bake the output transform into a shaper plus a 3D LUT and gate it against the golden data. Peak app footprint: about 490 MB neutral and 1.2 GB graded at 4K (873 MB graded without ACES), because of two more 4K half-float working frames.
- **Not verified:** the source-color picker and its hints in the running app; G8 (the owner's visual comparison of LUT and ACES on `P1107210` and `P1107158`); the ACES path's memory under G7's method (`profile-video.sh`, which includes `VTDecoderXPCService`).

## Task 11 result: instrumentation, memory pressure, playback gates

- **Instrumentation.** `VideoCompositorDiagnostics` emits a "VideoCompositor" signpost interval per frame request (ending "finished", "cancelled" or "failed") and a "GPU" event with the command buffer's `gpuEndTime − gpuStartTime`. The compositor's counters (`CompositorStatistics`) keep each finished frame's GPU time (the most recent 20 000), with median and maximum. Log lines (frame time, GPU time, cancellations, failures, memory-pressure releases) are opt-in with `PME_VIDEO_DIAGNOSTICS=1` or the `PerceptionVideoDiagnostics` bundle key, like the photo preview's.
- **Memory pressure.** `VideoCompositingEngine.releaseMemoryUnderPressure` now also clears the grade stage's Core Image caches and drops the scope tap's ring and latest capture, besides the waiting pool frames and CoreVideo's texture cache. Frames on the GPU keep what they hold. This is unit-tested; a real macOS pressure event during playback is NOT VERIFIED.
- **Profiling.** `scripts/profile-video.sh` gained `PME_PROFILE=playback`, which runs the new `RealVideoPlaybackTests` and samples the test process plus new `VTDecoderXPCService`s. That test plays a graded 1080p proxy of 60 s of `P1107157` (the golden grade with HSL and curves, the source color, and the scopes) with AVPlayer in real time, 10 times. A video output pulls frames at 120 Hz, and a clip frame it never receives counts as dropped (AVPlayer's own count needs a display). The first profile counted the in-test trim and proxy generation (+706 MB, decoder 430 MB). The test now creates a marker file when playback starts, and playback memory is measured from there.
- **Gate G1, playback part: FAIL** (release, 8 GB M1, 10 × 60 s, 14 380 frames per case).

  | Source color | Dropped frames | GPU per frame | Scopes |
  | --- | --- | --- | --- |
  | Panasonic V-Log to V-709 LUT (G1's case) | 6 (5 in the first run, 1 in the fourth) | median 5.3 ms, p99 10.9 ms, max 23.7 ms | 13.7 Hz |
  | ACES 2.0 (OCIO) | 1 (second run) | median 6.4 ms, p99 13.4 ms, max 29.0 ms | 13.7 Hz |

  The LUT case meets the 12 ms GPU limit at p99 but drops frames. ACES misses both limits. The drops are rare and cluster in the first run, so warm-up (first-use pipelines, pool growth) is the first suspect, but this is not established.
- **Gate G7, playback part: FAIL.** From the start of playback (LUT case): +513 MB, against a limit of +350 MB (app peak 481 MB, decoder peak 182 MB), with 31 000 pages swapped out during the run. The app's footprint after each run went 330, 349 and then 365 MB for runs 3–10, so it is a plateau, not a leak. That is still 35 MB over 10 runs against the 20 MB limit, so the growth check fails as written. ACES: 392 → 395 MB (2.9 MB growth).
- **G7, export part:** unchanged (Task 8: about 1.5 GB over idle, FAIL). This task added no memory reduction; the overruns now have the tooling to be worked on.

## Verification still owed

Task 0 measures feasibility only. G1–G9 in the plan remain open. The `VTDecoderXPCService` footprints are single samples taken mid-run. G7 must repeat them as peaks over whole runs.
