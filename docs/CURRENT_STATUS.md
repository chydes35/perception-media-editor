# Current status

Updated: 2026-10-14. Everything below is on `main` (PR #7 merged at `d9ccdb5`). Schema version **10**. Candidate build **16**; not yet signed or notarized for distribution. Long-form evidence from earlier passes is in [archive/](archive/README.md). The last full status snapshot is [archive/CURRENT_STATUS_2026-10-10.md](archive/CURRENT_STATUS_2026-10-10.md).

## What works

Card import with verified copies, culling, RAW develop (white balance with eyedropper, noise reduction, tone curve, HSL, Auto tone and white balance), presets with copy/paste/sync and history, gradient/brush/subject/sky masks, heal and clone, single-photo JPEG/PNG export, and sequential batch JPEG delivery. Video is a V1/A1 timeline with color, waveform, and fades; it is deferred until the photo gates pass.

## Verification

| Gate | Result |
|---|---|
| GitHub CI (macOS 15, Swift 6.1.2) | PASS: 320 tests, 292 executed / 28 skipped (no private RAW inputs on CI) |
| Local `./scripts/qa.sh` | PASS as of 2026-10-10: 302 executed / 18 skipped |
| 100 distinct S5 RAWs on the M1/8 GB target (import, cull, edit, export) | PASS: 100/100 full-resolution JPEGs; all original hashes unchanged; whole-app peak 1.53 GiB |
| Genuine single 100–200-photo shoot | NOT VERIFIED |
| Agreed performance thresholds | NOT VERIFIED (observations only; see [PERFORMANCE_TARGETS](PERFORMANCE_TARGETS.md)) |
| Distribution signing and notarization | NOT VERIFIED |

## In progress

White-balance drag latency ([plan](../plans/active/metal-canvas.md)): the renderer holds one RAW filter per current photo during white balance edits, so each exact render takes about 100-120 ms on a quiet machine, including the first one after opening a photo (330-980 ms before; slower under load) with the same pixels and no measurable extra memory. A drafted preview (a 5 ms shift of the as-shot decode) was tried and removed because the snap to the exact render was noticeable by eye. Not yet checked by a person: how dragging feels at about 8 renders per second.

Per-scene Look Matching ([plan](../plans/active/look-match-agent.md)), branch `look-match-lm1`, 2026-10-18: implemented with unit/integration tests (scene grouping, hero choice, 1 EV exposure solve, RAW WB mired offset including a real RW2 pair, selected-only apply as one undo step, stale and canceled runs, old report decoding, originals unchanged). Not yet verified on a real family-portrait shoot, in the running app, or for whole-app memory and time on the target Mac. Scene thresholds are starting values until that shoot is run.

## Open problems

1. **Black edited canvas (open bug).** After Export → New → Open → Photo, the edited preview can stay black although the render and histogram are valid; switching Original → Edited restores it. Cause not established. Publication-during-update faults and stale-completion races were fixed separately and are covered by tests. Evidence: [workspace transition](archive/WORKSPACE_TRANSITION_2026-10-10.md), [preview trace](archive/PREVIEW_TRACE_2026-10-09.md). Plan: [preview-reopen-recovery](../plans/active/preview-reopen-recovery.md). In progress on branch `metal-canvas` ([plan](../plans/active/metal-canvas.md)): the photo is drawn by a Metal view instead of SwiftUI `Image`. The Metal view is now merged (PR #9). On 2026-10-14 the release build of `main` with tracing on did **not** reproduce the black canvas in seven attempts (fresh launch → Add Files in Place → Photo; Library → Photo; project Save → New → Open → Photo ×5; every trace shows renderer, publish and a Metal draw with `image=true`, command buffer status completed). The bug is therefore still **not reproduced and not explained** on `main`; whether Metal removes it is **NOT VERIFIED** (not enough runs to claim). The Metal view now traces skipped draws and command-buffer status under `PME_PREVIEW_DIAGNOSTICS=1`, so the next occurrence will show whether the draw was skipped, failed on the GPU, or succeeded. `PME_SystemImageCanvas=1` compares against the old canvas.
2. **Selection quality.** Subject edge matting (hair wisps, spill) is implemented on branch `selection-quality` but not verified in the app. Fine edges and shaded sky gaps are weak, group members can be missed, and recovered masks spill at edges. See [selection quality](archive/SELECTION_QUALITY_2026-10-08.md).
3. **Not yet built:** reflection and broader lighting controls, color and luminance range masks, RAW+JPEG pairs, undo for ratings, persistent export recipes, output sharpening, P3, IPTC/copyright, watermark.
4. **`EditorStore` is too large** (about 1,450 lines, 100+ state properties). Splitting it is overdue.

## Next

Resolve the black canvas, then the selection-quality items, then run the genuine single-shoot acceptance and agree performance thresholds. Direction beyond that is in [ROADMAP](ROADMAP.md).
