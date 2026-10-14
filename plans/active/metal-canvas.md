# Metal photo canvas

Status: active  
Roadmap item: [Phase 2 reliability](../../docs/ROADMAP.md), related to [preview-reopen-recovery](preview-reopen-recovery.md)  
Owner: Claude

## User outcome and acceptance

The photo in Develop and Cull-compare is drawn by an `MTKView` through Core Image instead of SwiftUI `Image(nsImage:)`. It looks the same (same fit, same colors on an sRGB or P3 display) and keeps crop, mask, retouch, white-balance, subject picking and click-to-zoom aligned. The hope, **not yet established**, is that this removes the intermittent black edited canvas, which lives in the `CGImage` → `NSImage` → SwiftUI display path. Acceptance for that claim is the Export → New → Open → Photo sequence passing repeatedly on the target Mac, not tests alone.

## Staging

1. **This plan, step 1:** display-only swap. The renderer still produces a `CGImage`; the canvas draws it on the GPU. Fit math is a pure, tested function. A defaults switch (`PME_SystemImageCanvas`) restores the SwiftUI image for A/B comparison.
2. GPU histogram (`CIAreaHistogram`) so the preview no longer needs a CPU pass per render.
3. Deliver the lazy `CIImage` graph to the canvas (skip the `CGImage` bitmap) with a low-resolution drag preview.
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
- **Draft preview (implemented).** While a temperature slider moves, `PhotoRenderer.preview(..., allowsDraft: true)` shifts the cached as-shot decode with `WhiteBalanceShift` (Bradford adaptation between Planckian white points in linear sRGB) instead of re-decoding: 5–6 ms per tick *quiet*, after a one-time cold cost of about 0.27 s for the first use in a process. The result is flagged `isDraft`; `EditorStore` renders the exact decode after `draftSettleDelay` (350 ms) with no new input, cancels that on new input or project reset, and renders exactly when the requested decode is already cached. Only a temperature change on otherwise default RAW settings with no tint is drafted; tint or any other RAW setting uses the exact path as before.
- **Draft accuracy.** Against the exact decode (mean absolute error over RGB, 0–255): 3–6 for ±700–1500 K from as-shot, 8 at +3000 K, 10 at −1200 K (2910 K), 13 at −1500 K (2610 K); an unchanged image is off by 6–30. Four white-point/adaptation models and a mired scale factor were compared; all plateau at the same error, so the residual is the engine's nonlinear handling, not the model. Tint is not modeled.
- **Not verified:** how the snap from draft to exact looks and feels in the app; other RAW files, cameras and lighting; memory with a held filter.

- **Held filter (implemented, 2026-10-14).** `PhotoRenderer` keeps one `CIRAWFilter` for the current photo while it has a white balance edit and mutates `neutralTemperature`/`neutralTint` on later ticks. It is replaced when any other RAW setting changes or tint/temperature goes back to unset, and released on photo change, `evict`, `evictAll` and memory pressure. Pixels match a fresh decode (max difference 1/255, `HeldRawFilterTests`, opt-in via `PME_WB_RAW`). Full `preview` time, release build, load about 3: **held 102-120 ms for about 40% of ticks, 250-1350 ms for the rest; fresh renderer 480-1300 ms.** With `memoryTargetMB` 1024 one run was 121-160 ms on all 15 ticks and another 370-920 ms, so the bimodal spread is probably the engine dropping its cache, but this is **not established**; `PME_MEM_MB` in the test sets the target. Not checked by eye in the app, and the production target is still 256 MB.

- **Held filter on a quiet machine (load about 3).** Two S5 RAWs, two runs each, `memoryTargetMB` 256/512/1024/2048: exact renders are 90-165 ms on 13-15 of 15 ticks in every configuration, with an occasional 200-290 ms outlier, against 480 ms and up for a fresh renderer. The memory target made no clear difference, so the spread seen earlier was load, not the 256 MB target. Memory (`phys_footprint`, 40 ticks, one S5 RAW, both orders, 2 runs each): peak 551-571 MB with the held filter and 542-571 MB with a fresh filter per tick, so no measurable extra footprint (run-to-run noise is about 25 MB). The process stays near 550 MB after `evictAll` in both modes, so the footprint here is dominated by decode and Core Image caches, not by the held filter.
- **In the app (release build of this branch, one RAW, driven by computer use).** Dragging temperature to 2074 K ended in the exact blue render with an History entry; Reset Adjustments restored the photo. Screenshots cannot show the draft or the snap, so **how it feels is still NOT VERIFIED** by a person. The black edited canvas reproduced on first open of the photo (Original -> Edited restored it), so that bug is unchanged by this branch.

Next: have a person judge the draft/snap feel, then decide whether the draft is still needed (with the held filter reliably near 120 ms it may not be). The probe tests live outside the repository.

Caveat for the earlier measurements in this file: they were comparisons within a single run on the same machine, so the ratios should hold, but the absolute milliseconds may have been taken under some load.
