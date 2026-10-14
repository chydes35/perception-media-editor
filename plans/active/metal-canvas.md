# Metal photo canvas

Status: active  
Roadmap item: [Phase 2 reliability](../../docs/ROADMAP.md), related to [preview-reopen-recovery](preview-reopen-recovery.md)  
Owner: Claude

## User outcome and acceptance

The photo in Develop and Cull-compare is drawn by an `MTKView` through Core Image instead of SwiftUI `Image(nsImage:)`. It looks the same (same fit, same colors on an sRGB or P3 display) and keeps crop, mask, retouch, white-balance, subject picking and click-to-zoom aligned. The hope, **not yet established**, is that this removes the intermittent black edited canvas, which lives in the `CGImage` → `NSImage` → SwiftUI display path. Acceptance for that claim is the Export → New → Open → Photo sequence passing repeatedly on the target Mac, not tests alone.

## Staging

1. **This plan, step 1:** display-only swap. The renderer still produces a `CGImage`; the canvas draws it on the GPU. Fit math is a pure, tested function. A defaults switch (`PME_SystemImageCanvas`) restores the SwiftUI image for A/B comparison.
2. ~~GPU histogram (`CIAreaHistogram`)~~ **Dropped after measurement (2026-10-14).** The CPU histogram counts a 256-px downscale of the finished preview and takes about 0.55 ms in a release build. A `CIAreaHistogram` version fed the same `CGImage` was exact against a full-resolution count but took about 5.9 ms (upload plus synchronous readback), roughly 10× slower. Debug builds showed the opposite (GPU 6 ms vs CPU 26 ms) because the CPU loop is unoptimized there; always judge this by release numbers. Revisit only if step 3 leaves the histogram without a `CGImage` to read, and then measure again.
3. ~~Deliver the lazy `CIImage` graph to the canvas~~ **Paused after measurement (2026-10-14).** Release build, 3000×2000 JPEG, basic adjustments (exposure, contrast, highlights, shadows, warmth, vibrance, sharpness, vignette), 2000×1300 canvas, 30 ticks with a changing exposure: today's tick (render, read back to `CGImage`, histogram) averages about 13 ms; building the graph and drawing it straight into a Metal texture averages about 10 ms. That is roughly 3 ms of 13, and both are inside a 16 ms frame. Costs and risks of doing it anyway: graph evaluation and any CPU-side filter setup would move onto the main thread; masks, healing (which needs its own larger allocation context) and the sky/subject rasters would then be evaluated by the canvas's context instead of the memory-bounded renderer actor; the canvas would hold the working source buffer alive. The unmeasured part is the main-actor cost of publishing an `NSImage` and re-uploading it, which a direct path would avoid. Revisit if profiling a real 24 MP RAW with masks shows that cost, or if a drag-time proxy (render from a ~900 px copy of the source while a slider moves) is wanted. A proxy would be the larger lever, because Core Image filters run at the source's resolution.
4. Display P3 and EDR (`wantsExtendedDynamicRangeContent`) once the working pipeline outputs wide-gamut.

## Safety and performance

No project-schema, original-media, or renderer-memory changes. One shared `MTLDevice`, command queue and `CIContext` for all canvases (split view uses two). The view holds a reference to the already-published `CGImage`; no extra copies.

## Verification

| Gate | Required check | Result |
| --- | --- | --- |
| Unit | Fit-rect math; composed canvas pixels; real GPU draw into a Metal texture read back (orientation, transparent margins) | PASS — 4 tests |
| Build/CI | `./scripts/test.sh` locally and GitHub CI | PASS locally — 324 tests in 70 suites; GitHub CI pending |
| Runtime/UI | Target-Mac Develop, split, side-by-side, crop, mask, zoom; Export → New → Open → Photo repeated | NOT VERIFIED |

## Remaining work

Runtime verification on the target Mac, then steps 2–4.
