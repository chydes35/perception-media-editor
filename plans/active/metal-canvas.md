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

### White-balance latency (2026-10-14, preliminary)

Real S5 RAW, release build, Apple M1 / 8 GB. **The machine was under load** (an Android emulator using about 220% CPU, load average 6–9), so only minimums and robust relationships are recorded; medians were unusable.

- A white-balance tick builds a new `CIRAWFilter`, decodes, and renders into the half-float working buffer: about 340–460 ms best case, 0.5–1.3 s typical under load.
- **Filter creation is about 53 ms** of that (stable). Everything else is the decode and render.
- **Decode size does not matter.** The best case is about 310–340 ms at 800, 1024, 1280 and 1800 px alike. The demosaic runs at full resolution, so a smaller working copy or proxy cannot beat roughly 320 ms. (This is why the drag-proxy table shows no white-balance gain.)
- **Reusing one filter and changing `neutralTemperature` may cache the demosaic: 3 of 20 reused renders took about 100 ms.** But re-rendering an unchanged filter also ranged from 104 ms to 1.2 s, so the spread is contention and this is **not established**. Rerun on a quiet machine before building on it.
- **A Bradford chromatic-adaptation shift on the as-shot decode** (Planckian white points, 3×3 in linear sRGB) is a usable but rough drag-time stand-in: mean error 3.4–13 out of 255 across 2610–7110 K against 6.5–30 for the unchanged image (as-shot 4110 K). It ignores tint and the locus differs from the camera's definition of temperature, so it would need to snap to the exact decode on release.

Candidate designs, cheapest first: (1) keep one `CIRAWFilter` per photo and mutate it, if the quiet-machine rerun confirms the cache; (2) the approximation above as a drag preview with an exact render when the slider settles; (3) a per-photo fitted matrix from a few reference decodes. The probe tests live outside the repository; their shape is: time `makeRawFilter` + render for 20 temperatures with a fresh filter versus one mutated filter.

Caveat for the earlier measurements in this file: they were comparisons within a single run on the same machine, so the ratios should hold, but the absolute milliseconds were probably also taken under some load.

