# RAW highlight roll-off

Status: active
Roadmap item: [Phase 2 — RAW develop and presets](../../docs/ROADMAP.md) (highlight recovery)
Owner: lead coding agent (Claude Code)

## User outcome and acceptance

The photographer reported on 2026-10-19 that edited Lumix S5 RAW files "wash out" and that editing feels like pushing a JPEG. Investigation (confirmed by an independent check) found the cause. The RAW decode keeps highlights above white (`extendedDynamicRangeAmount = 2`, `PhotoRenderer.swift`), but every 8-bit output clips them with no roll-off: preview, before/after, 100% view and export. On a sunny-yard S5 frame (P1107263), 34.5% of pixels decode above white. The untouched preview clips 34.9% of pixels (any channel ≥ 254/255) against 14.5% for the camera's own JPEG. The Highlights slider (`CIHighlightShadowAdjust`) cannot pull those values back: at −1 it still leaves 14.6% clipped.

When this is done, RAW photos keep their decoded highlight detail and show it through a smooth shoulder, and the Highlights slider brings blown areas back.

Acceptance criteria:

1. For RAW sources only, a highlight shoulder maps linear values above white into the displayable range. *(Revised 2026-10-19, see Decisions.)* The pixel's luminance is mapped, so brightness rises monotonically with the data, and the color is scaled to match; a channel that ends up above 0.9 is eased toward white by desaturating toward the pixel's luminance. Colors whose luminance is below the knee and whose channels are within 0–0.9 are unchanged. The curve is continuous with slope 1 at the knee, is monotonic, and reaches white exactly at a white point. No output exceeds 1.
2. Untouched, P1107263 clips no more than the camera JPEG of the same frame (14.5% by the full-resolution measure). Median brightness stays within 0.02 (sRGB-encoded) of the current preview, so midtones do not move.
3. Highlights −1 on a RAW brings clipping on P1107263 under 2%, without lowering the median by more than 0.03.
4. Non-RAW photos, video clips, and RAW thumbnails drawn from the camera's embedded JPEG render byte-for-byte as before.
5. Preview, before/after "Original", 100% view, export and Auto's analysis all use the same shoulder for RAW, so what is shown is what is exported and analyzed.
6. No `.pmedit` change. Schema stays 12. Existing edits keep their values; they render with the new shoulder (accepted by the photographer on 2026-10-19).
7. Real-photo check: on the 2026-10-18 "Ivy 1 year" shoot copy, the photographer judges whether the untouched look and the photographer's own edits no longer look washed out. NOT VERIFIED until reported.

Out of scope: a Lumix-specific base profile (option 2, not chosen), HDR/EDR display, changing the decode range, changing video color.

## Current state and affected contracts

- `PhotoSourceLoader.makeRawFilter`: EDR 2 decode into an extended linear sRGB half-float working buffer (`PhotoRenderer.materialize`).
- `MediaColorRenderer.render(_:adjustments:includesGeometry:)` is shared by photo and timeline-clip rendering. Order: exposure → colorControls → highlightShadowAdjust → curves → temperature/tint → vibrance → HSL → grade → LUT → masks → sharpen → vignette → grain → crop. Curves, HSL and LUT expect values within 0–1.
- 8-bit sRGB output points: `PhotoRenderer.bitmap`, `original`, `focusRegion`, `export`. The Metal canvas draws the 8-bit preview.
- `PhotoSourceLoader.loadThumbnail` returns either the camera's embedded JPEG (no headroom) or a RAW decode.
- Contracts touched: the photo half of the shared color pipeline (video unchanged), the Highlights slider's effect on RAW photos, and the default RAW appearance.

## Implementation steps

1. Failing tests: curve properties; real-RAW clipping and median criteria; Highlights −1 recovery; non-RAW, video and embedded-thumbnail renders unchanged.
   - *Done.* `HighlightRolloffTests.swift`: curve properties (identity below the knee, slope 1, monotonic, exactly 1 at white), white point and knee from Highlights, an over-white synthetic pixel kept in range with its channel order, midtones untouched, which sources get the shoulder, RAW Highlights never lifting pixels back above white, and the two real-RAW criteria (`PME_ROLLOFF_RAW`). The first run failed to compile because the API did not exist yet.
2. `HighlightRolloff`: the curve, plus a Core Image color kernel applying it on the largest channel. `MediaColorRenderer.render` gains `highlightRolloff: Bool = false` and applies it after highlights/shadows, before curves.
   - *Done `168c275`, replaced in `a3f9a82`.* The first kernel mapped the largest channel and faded color toward white over the top of the shoulder (weight t²). That bleached sunlit colors and left a dark blue band in P1107332; see Decisions for the investigation and the current design.
3. The Highlights slider sets the white point for RAW: white = base × 2^(−2h), clamped. The existing `CIHighlightShadowAdjust` is kept for continuity.
   - *Done, changed from the plan.* Keeping `CIHighlightShadowAdjust` failed criterion 3. At −1 it left 3.5% clipped and lowered the median by 0.10, because the filter amplifies values above white (max 58 on P1107263 at −1). For RAW, the filter's highlight amount is now neutral, and the slider drives the shoulder alone: white = 4 × 2^(−2h), clamped 1.05–64; the knee is 0.6 × (1 + 0.5·min(0, h)). Its shadows control is unchanged. JPEG photos and video keep the old filter behavior exactly.
4. Callers pass `highlightRolloff` for RAW sources: preview, original, focus, export, the RAW-decoded thumbnail path, and Auto's RAW analysis.
   - *Done `168c275`.* `PhotoSourceLoader.hasHeadroom(_:)` is true for RAW files. `loadThumbnailSource` reports whether a thumbnail is a RAW decode or the camera's embedded JPEG. Auto's tone fit measures and renders candidates through the shoulder for RAW.
5. Tune the knee and base white point on the Ivy shoot against the camera JPEGs. Record the values and the evidence here.
   - *Done.* Knee 0.6 linear (about 0.80 sRGB-encoded) and base white 4.0 (two stops over). Untouched, preview-size, any channel ≥ 254:

     | Frame | Camera JPEG | Before | After | Median before → after |
     | --- | --- | --- | --- | --- |
     | P1107254 (patio) | 5.3% | 10.5% | 0.9% | 0.446 → 0.445 |
     | P1107263 (hero) | 14.6% | 34.9% | 4.7% | 0.638 → 0.638 |
     | P1107290 | 14.5% | 27.1% | 3.7% | 0.570 → 0.571 |
     | P1107332 (backlit blanket) | 24.9% | 34.7% | 6.1% | 0.659 → 0.659 |
     | P1107346 | 24.8% | 34.1% | 6.5% | 0.664 → 0.664 |
     | P1107374 | 20.9% | 32.4% | 6.1% | 0.661 → 0.662 |
     | P1107403 | 22.5% | 32.5% | 6.5% | 0.648 → 0.649 |
     | P1107420 | 28.2% | 33.9% | 5.2% | 0.625 → 0.623 |
     | P1107437 | 27.9% | 33.2% | 11.3% | 0.710 → 0.709 |
     | P1107452 (arch, bright sky) | 32.0% | 36.1% | 25.8% | 0.631 → 0.629 |
     | P1107465 (arch) | 24.2% | 28.3% | 18.0% | 0.499 → 0.498 |
     | P1107469 (arch) | 21.1% | 25.1% | 15.0% | 0.460 → 0.460 |

     (Table updated for `a3f9a82`. The first version clipped a little less, 0.2–4.5% and 13–24%, because it held channels well below white, which is what bleached color and made the band.)

     On the arch frames, the sky clips in the camera JPEG too; trees and water now show, but the sky stays white. Highlights −1 on P1107263 clips 1.8%, median 0.640 → 0.633 (at `a3f9a82`). A visual check by the coding agent of camera / before / after sheets (`~/Pictures/LM1-check/rolloff-survey2/`): highlight texture returns in grass, blanket and background. The overall look stays lighter and flatter than the camera JPEG, which is Apple's base RAW rendering and out of scope.
6. Docs (ARCHITECTURE, CURRENT_STATUS, ROADMAP line), QA, an independent check of the fix, and the photographer's visual check.

## Safety and performance

Rendering only; originals are read-only, and nothing new is persisted. The kernel is one per-pixel pass on the GPU in the existing graph, so no extra buffers or caches are added. Measure preview render time before and after on a real RW2. The target is under 5% added time.

## Verification

| Gate | Required check | Result and evidence |
| --- | --- | --- |
| Static/build | `git diff --check`; Swift build | **PASS** — clean diff check; build with no new warnings besides the existing CIKL deprecation (same as Retouch) |
| Unit/integration | Focused tests, then the full suite (QA substitute: `rg` is not installed here) | **PASS by substitute** — focused `HighlightRolloff` 9/9 with the real RW2; photo render, Auto, export and preset suites 224/224; full suite at `168c275`: 664 tests in 126 suites passed, 618 executed / 46 skipped, app build passed. Verification-runner: with the MediaColorRenderer change reverted, untouched P1107263 clips 35.0% and Highlights −1 still clips 14.7% (median 0.637 → 0.527); with it, 2.0% and 0.0% |
| Runtime/UI | Develop a real RW2 in the app: untouched look, Highlights −1, before/after, export | PENDING |
| Media quality | Ivy shoot: clipping and median vs camera JPEG; photographer's visual check | **PARTIAL** — 12-frame measurements above meet criteria 2–3 on the hero frame. The photographer's visual check (criterion 7) is NOT VERIFIED |
| Performance | Preview render time on a real RW2, before vs after | **PASS (measured, test process)** — 2560 px render of P1107263 with typical edits on this 8 GB M1, 20 renders each, median: 21.7 / 20.9 ms without the shoulder, 21.4 / 21.5 ms with it (no measurable change) |

## Decisions, discoveries, and remaining work

- 2026-10-19 (photographer): option 1 chosen. Keep the RAW headroom, add a roll-off, and make Highlights recover it. A Lumix base profile was not chosen.
- The shoulder goes before curves, HSL and LUTs, which need values within 0–1. A local mask that brightens a highlight can still exceed white after the shoulder; this is a known limitation.
- 2026-10-19 (photographer's check in the combined build, then investigation): two faults in `168c275`.
  1. *Bleached color.* Sunlit yellow mums on P1107263 went pale cream. Mean saturation of the untouched preview fell from 0.373 to 0.333: the t² color fade started at the knee.
  2. *Dark blue band* along the top of P1107332, between bright sky and sunlit grass blown to white (the photographer corrected an earlier note that called it a lake). A pixel trace down the band showed the cause. The decode there is real bright sky, e.g. linear (0.74, 1.24, 2.05). Mapping the largest channel (blue, 2.05) scaled red and green down with it, giving sRGB (0.66, 0.80, 0.97). That is darker than the dimmer sky above it, (0.67, 0.78, 0.88), and darker than the camera JPEG's (0.94, 0.99, 1.00). A test counting pixels the camera shows near white (luma ≥ 0.93) that the editor shows ≥ 0.12 darker found 11.05% of that area.
  - Tried and rejected on the way: a saturation-weighted fade (band remained); fading only near the white point (band remained); turning RAW highlight recovery off (magenta false color where the sensor clipped). An area-maximum or plateau detector for the sensor's clip level failed: the decoded channels show no plateau, under 0.2% of pixels within 1% of the 99.9th percentile.
  - **Design at `a3f9a82`.** (a) The shoulder maps luminance and eases any channel above 0.9 toward white by desaturating toward the pixel's luminance. Colors in range are untouched. (b) `RecoveredHighlights` (macOS 26, **removed in `69aac92`**, see next item): two 512 px draft decodes, with the RAW engine's highlight recovery on and off, differ only where the sensor clipped and the engine rebuilt the highlight. In that smoothed mask, near-neutral pixels (saturation under 0.3, fully at 0.7 and above left alone) are made neutral at their own brightness. The mask is cached per file, modification date and RAW settings (24 entries) and cleared on memory pressure and project replacement. On macOS 15 the step is skipped.
  - Results: dark rim 11.05% → 0.90%. P1107263 saturation 0.363 before → 0.367 now (no bleaching; the before value moved slightly with the draft-quality mask). Clipping 34.9% → 4.6%, median 0.640 → 0.640. Highlights −1: 1.8% clipped, median 0.633. A visual check of a full-size crop: the sky fades smoothly into the white grass with no band, close to the camera JPEG.
  - Cost on this 8 GB M1, median of 6 RAW files: a 2560 px load takes 1.11 s without the step, 1.79 s on first open and 0.50 s with the mask cached. A 512 px analysis load takes 0.74 s without, 1.67 s first. Look Match therefore pays about 0.9 s more per photo on its first pass. Possible optimization, not done: skip the step for analysis-size loads, or compute the mask asynchronously.
- 2026-10-19 (`69aac92`): `RecoveredHighlights` removed. The verification-runner showed the band reading is 0.90% with or without it, so the luminance shoulder alone fixes the band (the color-keeping max-channel kernel reproduces it at 11.04%). With the step, sunlit mums whose petals clipped at the sensor (P1107437) went pale in a side-by-side render, and P1107263 failed the bleach test against the plain decode (0.367 vs 0.373). It also cost 0.7–0.9 s per first RAW open. Without it, both bleach cases pass (P1107263 0.373 → 0.377, P1107437 0.310 → 0.316), the band stays at 0.90%, untouched P1107263 clips 5.0% (camera JPEG 14.6%) with median 0.638 → 0.638, and Highlights −1 clips 1.9%. RAW load time is back to the pre-step cost. **Current design: the luminance shoulder only.** Full suite at `69aac92`: 666 tests in 127 suites passed, 618 executed / 48 skipped, app build passed. Verification-runner: restoring the step fails the bleach test on P1107263 (0.367 vs 0.373); P1107437 alone moves only 0.003 in whole-frame mean saturation, within the 0.005 tolerance, so P1107263 is the frame that guards this.
