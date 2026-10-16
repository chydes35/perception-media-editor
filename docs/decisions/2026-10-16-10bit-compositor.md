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

## Verification still owed

Task 0 measures feasibility only. G1–G9 in the plan remain open. The `VTDecoderXPCService` footprints are single samples taken mid-run. G7 must repeat them as peaks over whole runs.
