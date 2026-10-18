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

### Drag-proxy measurement (2026-10-14)

Release build on an Apple M1, 8 GB, using a copy of a real Lumix S5 RW2 (24 MP). Edit: exposure, contrast, highlights, shadows, vibrance, sharpness, vignette, an RGB tone curve, HSL, one radial and one linear mask. A renderer with a smaller working copy and preview, compared with today's 2560/1800:

| Renderer | Output | First open | Look-slider tick (cached source) | White-balance tick (re-decode) |
| --- | --- | --- | --- | --- |
| Today, 2560 / 1800 | 1800×1201 | 0.75–1.6 s | 16–17 ms | 0.42–0.73 s |
| Proxy, 1280 / 900 | 900×601 | 0.30–0.61 s | 5.6–7.6 ms | 0.33–0.43 s |
| Proxy, 1024 / 700 | 700×467 | 0.26–0.29 s | 4.5–4.8 ms | 0.35–0.38 s |

Reading: look sliders get about 2.5× cheaper (16 ms, at the edge of a 60 Hz frame, to about 6 ms), which leaves room for heavier edits than this one. The RAW-decode controls (white balance, noise reduction, detail, lens correction) barely improve, because the decode, not the output size, dominates; they stay at roughly half a second. Costs to weigh: the image is visibly softer while dragging, and sharpness, detail, noise reduction and vignette cannot be judged on a proxy, so those sliders would need to stay at full resolution; a second, smaller working copy per photo (about 9 MB versus 35 MB at half-float RGBA); and a new "a slider is being dragged" signal in the store, which does not exist today for the Develop sliders. Two runs, one machine, one photo; the first-open column is noisy. Not yet checked: heavier edits (healing, brush and sky masks) and a 100+ photo session.

Decision pending: build it only if look sliders feel laggy on real shoots; the benchmark harness is not kept (see the commit history for its shape).
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

### Black canvas retest on main (2026-10-14)

Release build of `main` (Metal canvas), `PME_PREVIEW_DIAGNOSTICS=1`, driven by computer use with `P1107138.RW2` added in place. Seven first-open attempts displayed the photo every time (the empty "Select a photo" frame is shown for about a second while the first render runs, then replaced): fresh launch → Add Files in Place → Photo; Library → Photo; Save → New → Open → Photo five times; one cold launch → Open → Photo. Each trace has renderer preview, store publish and `metal canvas drew ... image=true`. **Not reproduced**, so Metal neither confirmed nor ruled out as the cure.

Tried and discarded: a redraw-on-layout hook and bounded retry on GPU failure. A test that moved the view into a window passed with the hook disabled, so AppKit already requests the redraw on resize and the hook was unproven; both were removed. Kept: trace lines for a skipped draw (drawable size, window presence) and the command buffer's final status/error. Next time the canvas goes black with diagnostics on, those lines say whether the draw never happened, errored, or completed.
