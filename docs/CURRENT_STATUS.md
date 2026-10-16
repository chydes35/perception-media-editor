# Current status

Updated: 2026-10-16. Everything below is on `main` (PR #7 merged at `d9ccdb5`) unless marked as branch `feat/video-proxies` (pending merge). Schema version **10**. Candidate build **16**; not yet signed or notarized for distribution. Long-form evidence from earlier passes is in [archive/](archive/README.md). The last full status snapshot is [archive/CURRENT_STATUS_2026-10-10.md](archive/CURRENT_STATUS_2026-10-10.md).

## What works

Card import with verified copies, culling, RAW develop (white balance with eyedropper, noise reduction, tone curve, HSL, Auto tone and white balance), presets with copy/paste/sync and history, gradient/brush/subject/sky masks, heal and clone, single-photo JPEG/PNG export, and sequential batch JPEG delivery. Video is a V1/A1 timeline with color, waveform, and fades; it is deferred until the photo gates pass, except that the proxy pipeline was pulled forward as its prerequisite. On branch `feat/video-proxies` (pending merge), video proxies (ProRes 422 Proxy) are generated automatically and can be toggled with "Proxies" in the timeline toolbar. Proxies are used only for playback; sound always comes from the originals, and the originals are kept for export once video export exists. Hands-on UI walkthrough is NOT VERIFIED.

## Verification

| Gate | Result |
|---|---|
| GitHub CI (macOS 15, Swift 6.1.2) | PASS: 320 tests, 292 executed / 28 skipped (no private RAW inputs on CI) |
| Local `./scripts/qa.sh` | Last PASS 2026-10-10 (302 executed / 18 skipped); not re-run since, and not runnable on this Mac's Command Line Tools |
| 100 distinct S5 RAWs on the M1/8 GB target (import, cull, edit, export) | PASS: 100/100 full-resolution JPEGs; all original hashes unchanged; whole-app peak 1.53 GiB |
| Genuine single 100–200-photo shoot | NOT VERIFIED |
| Agreed performance thresholds | NOT VERIFIED (observations only; see [PERFORMANCE_TARGETS](PERFORMANCE_TARGETS.md)) |
| Video proxies (branch `feat/video-proxies`, pending merge): unit/integration and real S5 media (frame-exact, 68.5 fps at `.utility` QoS vs 28.8 fps gate) | PASS (full suite via CLT wrapper on 2026-10-16: 374 tests, 351 executed / 23 skipped, 0 failed; `qa.sh` itself not runnable on this Mac) |
| Video proxies (branch `feat/video-proxies`, pending merge): Runtime/UI walkthrough, UI responsiveness during generation | NOT VERIFIED |
| Distribution signing and notarization | NOT VERIFIED |

## Open problems

1. **Black edited canvas (open bug).** After Export → New → Open → Photo, the edited preview can stay black although the render and histogram are valid; switching Original → Edited restores it. Cause not established. Publication-during-update faults and stale-completion races were fixed separately and are covered by tests. Evidence: [workspace transition](archive/WORKSPACE_TRANSITION_2026-10-10.md), [preview trace](archive/PREVIEW_TRACE_2026-10-09.md). Plan: [preview-reopen-recovery](../plans/active/preview-reopen-recovery.md). In progress on branch `metal-canvas` ([plan](../plans/active/metal-canvas.md)): the photo is drawn by a Metal view instead of SwiftUI `Image`. The Metal view is now merged (PR #9). On 2026-10-14 the release build of `main` with tracing on did **not** reproduce the black canvas in seven attempts (fresh launch → Add Files in Place → Photo; Library → Photo; project Save → New → Open → Photo ×5; every trace shows renderer, publish and a Metal draw with `image=true`, command buffer status completed). The bug is therefore still **not reproduced and not explained** on `main`; whether Metal removes it is **NOT VERIFIED** (not enough runs to claim). The Metal view now traces skipped draws and command-buffer status under `PME_PREVIEW_DIAGNOSTICS=1`, so the next occurrence will show whether the draw was skipped, failed on the GPU, or succeeded. `PME_SystemImageCanvas=1` compares against the old canvas.
2. **Selection quality.** Subject edge matting (hair wisps, spill) is implemented on branch `selection-quality` but not verified in the app. Fine edges and shaded sky gaps are weak, group members can be missed, and recovered masks spill at edges. See [selection quality](archive/SELECTION_QUALITY_2026-10-08.md).
3. **Not yet built:** reflection and broader lighting controls, color and luminance range masks, RAW+JPEG pairs, undo for ratings, persistent export recipes, output sharpening, P3, IPTC/copyright, watermark.
4. **`EditorStore` is too large** (about 1,450 lines, 100+ state properties). Splitting it is overdue.

## Next

Resolve the black canvas, then the selection-quality items, then run the genuine single-shoot acceptance and agree performance thresholds. Direction beyond that is in [ROADMAP](ROADMAP.md).
