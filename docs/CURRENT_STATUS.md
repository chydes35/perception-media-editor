# Current status

Updated: 2026-10-20. Application status below describes `main`; the isolated stabilization research section names its separate branch. Schema version **10**. Candidate build **16**; not yet signed or notarized for distribution. Long-form evidence from earlier passes is in [archive/](archive/README.md). The last full status snapshot is [archive/CURRENT_STATUS_2026-10-10.md](archive/CURRENT_STATUS_2026-10-10.md).

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

Per-scene Look Matching ([plan](../plans/active/look-match-agent.md)), branch `look-match-lm1`, 2026-10-18: implemented with unit/integration tests (scene grouping, hero choice, 1 EV exposure solve, RAW WB mired offset including a real RW2 pair, selected-only apply as one undo step, stale and canceled runs, old report decoding, originals unchanged). Analysis was run on the real 2026-10-18 family shoot (221 RW2): 4 scenes, 215 proposals, 1 correctly flagged, about 1–3 s per photo in the test process; confidence scoring was corrected from that run. On 2026-10-19 it ran in the app on that shoot (about 11 minutes, 586 MB peak footprint); Apply Selected and one undo worked. That run found that a photo with only a white-balance edit lost it, which is now fixed. Not yet verified: the photographer's kept/touched count, an agreed time/memory limit, and a shoot with mixed window/shade/flash light.

RAW highlight roll-off ([plan](../plans/active/raw-highlight-rolloff.md)), 2026-10-19. The photographer reported washed-out RAW edits. Cause: highlights decoded above white were clipped at every 8-bit output, and Core Image's highlight filter amplified them. RAW renders now use a luminance highlight shoulder that Highlights drives. On 12 frames of the 2026-10-18 family shoot, untouched clipping fell from 25–36% to 1–11% on 9 frames and to 15–26% on 3 backlit frames whose sky is blown in the file (camera JPEGs 5–32%), with midtones unchanged, no loss of saturation, and no dark band at the edge of blown areas. RAW load time is unchanged. Not yet verified: the photographer's visual check in the app of the final look on this branch. Unchanged: Apple's base RAW rendering stays lighter and flatter than the camera JPEG.

## Isolated video stabilization research

Branch `codex/video-stabilization-poc`, 2026-10-20: the owner authorized only baseline
audit and proof of concept (M0/M1), with the full future scope in the
[ExecPlan](../plans/active/video-stabilization.md). A standalone AVFoundation/Vision/Core Image
harness outside the app compares translation, constrained homography and an external
vid.stab library adapter on synthetic and original S5/iPhone footage. The app, UI,
project schema and production dependencies are unchanged. Corrected native diagnostic
output preserves exact source PTS; original-quality log/10-bit/HDR delivery is not
implemented. Baseline tests/build pass with SDK 26.5 and SwiftPM's native build system
(382 reported tests, 351 passed / 31 skipped declarations).

**NO-GO for M2 production-engine selection:** homography misses a known cut, confidence
does not establish reliable tracking on uniform images, translation increases measured
jitter on the tested iPhone excerpts, neutral diagnostic color drifts, and labeled interview/walking/
pan scenarios and human quality acceptance remain open. The owner will review those
scenarios later. See [measurements and limitations](archive/VIDEO_STABILIZATION_PROTOTYPE_2026-10-20.md).
M2–M6 remain unstarted; existing photo-first priorities below still apply.

## Open problems

1. **Black edited canvas (open bug).** After Export → New → Open → Photo, the edited preview can stay black although the render and histogram are valid; switching Original → Edited restores it. Cause not established. Publication-during-update faults and stale-completion races were fixed separately and are covered by tests. Evidence: [workspace transition](archive/WORKSPACE_TRANSITION_2026-10-10.md), [preview trace](archive/PREVIEW_TRACE_2026-10-09.md). Plan: [preview-reopen-recovery](../plans/active/preview-reopen-recovery.md). In progress on branch `metal-canvas` ([plan](../plans/active/metal-canvas.md)): the photo is drawn by a Metal view instead of SwiftUI `Image`. The Metal view is now merged (PR #9). On 2026-10-14 the release build of `main` with tracing on did **not** reproduce the black canvas in seven attempts (fresh launch → Add Files in Place → Photo; Library → Photo; project Save → New → Open → Photo ×5; every trace shows renderer, publish and a Metal draw with `image=true`, command buffer status completed). The bug is therefore still **not reproduced and not explained** on `main`; whether Metal removes it is **NOT VERIFIED** (not enough runs to claim). The Metal view now traces skipped draws and command-buffer status under `PME_PREVIEW_DIAGNOSTICS=1`, so the next occurrence will show whether the draw was skipped, failed on the GPU, or succeeded. `PME_SystemImageCanvas=1` compares against the old canvas.
2. **Selection quality.** Subject edge matting (hair wisps, spill) is implemented on branch `selection-quality` but not verified in the app. Fine edges and shaded sky gaps are weak, group members can be missed, and recovered masks spill at edges. See [selection quality](archive/SELECTION_QUALITY_2026-10-08.md).
3. **Not yet built:** reflection and broader lighting controls, color and luminance range masks, RAW+JPEG pairs, undo for ratings, persistent export recipes, output sharpening, P3, IPTC/copyright, watermark.
4. **`EditorStore` is too large** (about 1,450 lines, 100+ state properties). Splitting it is overdue.

## Next

Resolve the black canvas, then the selection-quality items, then run the genuine single-shoot acceptance and agree performance thresholds. Direction beyond that is in [ROADMAP](ROADMAP.md).
