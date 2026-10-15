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

### Black canvas retest on main (2026-10-14)

Release build of `main` (Metal canvas), `PME_PREVIEW_DIAGNOSTICS=1`, driven by computer use with `P1107138.RW2` added in place. Seven first-open attempts displayed the photo every time (the empty "Select a photo" frame is shown for about a second while the first render runs, then replaced): fresh launch → Add Files in Place → Photo; Library → Photo; Save → New → Open → Photo five times; one cold launch → Open → Photo. Each trace has renderer preview, store publish and `metal canvas drew ... image=true`. **Not reproduced**, so Metal neither confirmed nor ruled out as the cure.

Tried and discarded: a redraw-on-layout hook and bounded retry on GPU failure. A test that moved the view into a window passed with the hook disabled, so AppKit already requests the redraw on resize and the hook was unproven; both were removed. Kept: trace lines for a skipped draw (drawable size, window presence) and the command buffer's final status/error. Next time the canvas goes black with diagnostics on, those lines say whether the draw never happened, errored, or completed.
