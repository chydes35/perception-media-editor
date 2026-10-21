# Current status

Updated: 2026-10-21 (M0 documentary reconciliation). Application baseline is `main` at `0d3283aa9063bb081ac39554a66221c5e87db53f`, including merged PR #15 (Look Match) and PR #16 (RAW highlight roll-off). The M0 documentation/tooling candidate has its own branch; see the [pinned repository audit](research/mpkb-v2/m0-repository-baseline.md). Schema version **10**. Candidate build **16**; not yet signed or notarized for distribution. Long-form evidence from earlier passes is in [archive/](archive/README.md). The last full status snapshot is [archive/CURRENT_STATUS_2026-10-10.md](archive/CURRENT_STATUS_2026-10-10.md).

## What works

Card import with verified copies, culling, RAW develop (white balance with eyedropper, noise reduction, tone curve, HSL, Auto tone and white balance), presets with copy/paste/sync and history, gradient/brush/subject/sky masks, heal and clone, single-photo JPEG/PNG export, and sequential batch JPEG delivery. Video is a V1/A1 timeline with color, waveform, and fades; it is deferred until the photo gates pass.

## Verification

| Gate | Result |
|---|---|
| Pinned-main GitHub CI (macOS 15, Swift 6.1.2; run 39315828017, 2026-10-19) | PASS: 382 reported tests, 341 executed / 41 skipped; logs freshly retrieved 2026-10-21. Private fixture checks remain NOT VERIFIED |
| Local `./scripts/qa.sh` | FAIL on 2026-10-21 before tests: sandbox build-service write permission, then default SDK macro-plugin discovery on approved retry. SDK 26.5/native test fallback and build PASS: 382 reported, 341 executed / 41 skipped. See [M0 command/evidence matrix](research/mpkb-v2/m0-test-gates.md) |
| M0 candidate full SDK 26.5/native suite on nine approved RAW copies | PASS: 382 reported tests, 357 executed / 25 skipped, 0 failures; app build PASS. Includes an independently verified orientation-only test assertion correction; app code unchanged |
| Historical local QA (2026-10-10) | PASS at its recorded revision: 302 executed / 18 skipped; not a fresh M0 run |
| Historical 100-distinct-S5 varied-library target run (see PERFORMANCE_TARGETS) | PASS: 100/100 full-resolution JPEGs; all original hashes unchanged; whole-app peak 1.53 GiB |
| Genuine single 100–200-photo shoot | NOT VERIFIED |
| Agreed performance thresholds | NOT VERIFIED (observations only; see [PERFORMANCE_TARGETS](PERFORMANCE_TARGETS.md)) |
| Distribution signing and notarization | NOT VERIFIED |

## In progress

White-balance drag latency ([plan](../plans/active/metal-canvas.md)): the renderer holds one RAW filter per current photo during white balance edits, so each exact render takes about 100-120 ms on a quiet machine, including the first one after opening a photo (330-980 ms before; slower under load) with the same pixels and no measurable extra memory. A drafted preview (a 5 ms shift of the as-shot decode) was tried and removed because the snap to the exact render was noticeable by eye. Not yet checked by a person: how dragging feels at about 8 renders per second.

Per-scene Look Matching ([active acceptance plan](../plans/active/look-match-agent.md)), implementation merged via PR #15 (original branch `look-match-lm1`), 2026-10-18: implemented with unit/integration tests (scene grouping, hero choice, 1 EV exposure solve, RAW WB mired offset including a real RW2 pair, selected-only apply as one undo step, stale and canceled runs, old report decoding, originals unchanged). Analysis was run on the real 2026-10-18 family shoot (221 RW2): 4 scenes, 215 proposals, 1 correctly flagged, about 1–3 s per photo in the test process; confidence scoring was corrected from that run. On 2026-10-19 it ran in the app on that shoot (about 11 minutes, 586 MB peak footprint); Apply Selected and one undo worked. That run found that a photo with only a white-balance edit lost it, which is now fixed. Not yet verified: the photographer's kept/touched count, an agreed time/memory limit, and a shoot with mixed window/shade/flash light.

RAW highlight roll-off ([plan](../plans/active/raw-highlight-rolloff.md)), 2026-10-19. The photographer reported washed-out RAW edits. Cause: highlights decoded above white were clipped at every 8-bit output, and Core Image's highlight filter amplified them. RAW renders now use a luminance highlight shoulder that Highlights drives. On 12 frames of the 2026-10-18 family shoot, untouched clipping fell from 25–36% to 1–11% on 9 frames and to 15–26% on 3 backlit frames whose sky is blown in the file (camera JPEGs 5–32%), with midtones unchanged, no loss of saturation, and no dark band at the edge of blown areas. RAW load time is unchanged. Not yet verified: the photographer's visual check in the app of the final look on `main`. Unchanged: Apple's base RAW rendering stays lighter and flatter than the camera JPEG.

## Open problems

1. **Black edited canvas (open bug).** After Export → New → Open → Photo, the edited preview can stay black although the render and histogram are valid; switching Original → Edited restores it. Cause not established. Publication-during-update faults and stale-completion races were fixed separately and are covered by tests. Evidence: [workspace transition](archive/WORKSPACE_TRANSITION_2026-10-10.md), [preview trace](archive/PREVIEW_TRACE_2026-10-09.md). Plan: [preview-reopen-recovery](../plans/active/preview-reopen-recovery.md). The Metal implementation from branch `metal-canvas` is merged (PR #9); its [acceptance plan](../plans/active/metal-canvas.md) remains active: the photo is drawn by a Metal view instead of SwiftUI `Image`. On 2026-10-14 the release build of `main` with tracing on did **not** reproduce the black canvas in seven attempts (fresh launch → Add Files in Place → Photo; Library → Photo; project Save → New → Open → Photo ×5; every trace shows renderer, publish and a Metal draw with `image=true`, command buffer status completed). The bug is therefore still **not reproduced and not explained** on `main`; whether Metal removes it is **NOT VERIFIED** (not enough runs to claim). The Metal view now traces skipped draws and command-buffer status under `PME_PREVIEW_DIAGNOSTICS=1`, so the next occurrence will show whether the draw was skipped, failed on the GPU, or succeeded. `PME_SystemImageCanvas=1` compares against the old canvas.
2. **Selection quality.** Subject edge matting (hair wisps, spill) is implemented on branch `selection-quality` but not verified in the app. Fine edges and shaded sky gaps are weak, group members can be missed, and recovered masks spill at edges. See [selection quality](archive/SELECTION_QUALITY_2026-10-08.md).
3. **Not yet built:** reflection and broader lighting controls, color and luminance range masks, RAW+JPEG pairs, undo for ratings, persistent export recipes, output sharpening, P3, IPTC/copyright, watermark.
4. **`EditorStore` is too large** (about 1,450 lines, 100+ state properties). Splitting it is overdue.

## M0 baseline validation

[MPKB V2 M0](research/mpkb-v2/README.md) remains active. The source audit and target hardware identity are established; approved nine-file copied-RAW diagnostics are separate from full scene/camera-JPEG coverage, genuine single-shoot performance and photographer acceptance. No application rendering, schema, timeline or dependencies changed. The named full blueprint was unavailable, so WP-000 research registration and exact exit criteria remain NOT VERIFIED.

## Next

Resolve the black canvas, then the selection-quality items, then run the genuine single-shoot acceptance and agree performance thresholds. Direction beyond that is in [ROADMAP](ROADMAP.md).
