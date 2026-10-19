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

### White-balance latency (2026-10-14)

Real S5 RAW, release build, Apple M1 / 8 GB. The first runs were under load from an Android emulator and unusable beyond minimums; the numbers below marked *quiet* were taken afterwards (load average about 2).

- **Why a tick is slow.** Each white-balance tick builds a new `CIRAWFilter`, decodes and renders: 332–700 ms *quiet* (0.5–1.3 s under load). Filter creation is about 53 ms of that. The demosaic cost does not shrink with output size: the best case is about 310–340 ms at 800, 1024, 1280 and 1800 px alike, which is why the drag proxy shows no white-balance gain.
- **Reusing one filter works.** *Quiet:* with one `CIRAWFilter` and only `neutralTemperature` changed, most renders take 91–99 ms, the same as re-rendering an unchanged filter (90–95 ms), against 330–700 ms for a fresh filter. A minority of reused renders still take 200–700 ms (unexplained; possibly the engine dropping its cache under the context's 256 MB target). **Not yet implemented**; it needs a policy for holding one filter (and its decoded data) for the current photo only, released on photo change and memory pressure.
- **Draft preview (tried, removed 2026-10-14).** Shifting the cached as-shot decode with a Bradford adaptation cost 5-6 ms per tick, with 3-13/255 mean error against the exact decode (up to 13 at the extremes, tint not modeled). Judged by eye in the app: **the snap from draft to exact was noticeable**, and the held filter makes exact renders about 120 ms, so the draft and its 350 ms settle logic were removed (history: commit e81db9f).

- **Held filter (implemented, 2026-10-14).** `PhotoRenderer` keeps one `CIRAWFilter` for the current photo while it has a white balance edit and mutates `neutralTemperature`/`neutralTint` on later ticks. It is replaced when any other RAW setting changes or tint/temperature goes back to unset, and released on photo change, `evict`, `evictAll` and memory pressure. Pixels match a fresh decode (max difference 1/255, `HeldRawFilterTests`, opt-in via `PME_WB_RAW`). Full `preview` time, release build, load about 3: **held 102-120 ms for about 40% of ticks, 250-1350 ms for the rest; fresh renderer 480-1300 ms.** With `memoryTargetMB` 1024 one run was 121-160 ms on all 15 ticks and another 370-920 ms, so the bimodal spread is probably the engine dropping its cache, but this is **not established**; `PME_MEM_MB` in the test sets the target. Not checked by eye in the app, and the production target is still 256 MB.

- **Held filter on a quiet machine (load about 3).** Two S5 RAWs, two runs each, `memoryTargetMB` 256/512/1024/2048: exact renders are 90-165 ms on 13-15 of 15 ticks in every configuration, with an occasional 200-290 ms outlier, against 480 ms and up for a fresh renderer. The memory target made no clear difference, so the spread seen earlier was load, not the 256 MB target. Memory (`phys_footprint`, 40 ticks, one S5 RAW, both orders, 2 runs each): peak 551-571 MB with the held filter and 542-571 MB with a fresh filter per tick, so no measurable extra footprint (run-to-run noise is about 25 MB). The process stays near 550 MB after `evictAll` in both modes, so the footprint here is dominated by decode and Core Image caches, not by the held filter.
- **In the app (release build of this branch, one RAW, driven by computer use).** Dragging temperature to 2074 K ended in the exact blue render with an History entry; Reset Adjustments restored the photo. Screenshots cannot show the draft or the snap, so **how it feels is still NOT VERIFIED** by a person. The black edited canvas reproduced on first open of the photo (Original -> Edited restored it), so that bug is unchanged by this branch.

- **Filter held from the first decode (2026-10-14).** A RAW photo's as-shot decode now builds the held filter too, and every decode sets temperature and tint explicitly (as-shot when unset), so the first white balance edit mutates it instead of decoding again. Quiet machine, one S5 RAW, 5 fresh renderers each: **first tick after opening 99-119 ms (was 254-979 ms)**; later ticks 99-128 ms with two outliers near 200 ms (were 98-924 ms). Mutated-through-edits pixels match a from-scratch filter within 1/255 for as-shot, temperature, tint, tint cleared and temperature-only settings. Memory with the held filter was measured before this change; the filter is now also held for photos never white-balanced, one photo at a time.

Next: have a person judge how dragging feels with exact renders at about 100 ms; consider a coarser proxy or throttle only if it feels laggy. The probe tests live outside the repository.

Caveat for the earlier measurements in this file: they were comparisons within a single run on the same machine, so the ratios should hold, but the absolute milliseconds may have been taken under some load.

### Black canvas retest on main (2026-10-14)

Release build of `main` (Metal canvas), `PME_PREVIEW_DIAGNOSTICS=1`, driven by computer use with `P1107138.RW2` added in place. Seven first-open attempts displayed the photo every time (the empty "Select a photo" frame is shown for about a second while the first render runs, then replaced): fresh launch → Add Files in Place → Photo; Library → Photo; Save → New → Open → Photo five times; one cold launch → Open → Photo. Each trace has renderer preview, store publish and `metal canvas drew ... image=true`. **Not reproduced**, so Metal neither confirmed nor ruled out as the cure.

Tried and discarded: a redraw-on-layout hook and bounded retry on GPU failure. A test that moved the view into a window passed with the hook disabled, so AppKit already requests the redraw on resize and the hook was unproven; both were removed. Kept: trace lines for a skipped draw (drawable size, window presence) and the command buffer's final status/error. Next time the canvas goes black with diagnostics on, those lines say whether the draw never happened, errored, or completed.
