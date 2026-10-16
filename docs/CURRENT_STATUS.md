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
| Video proxies of full-range sources (S5 V-Log), branch `plan/10bit-vlog-color` | FIXED, not yet on `feat/video-proxies`. Proxies made before it are about 17% too bright (AVFoundation's x422 read of a full-range source adds 64 to luma without rescaling). Real `P1107158` proxy now within 1.8/1023 of the original (104.5 before). The proxy key version is 2, so old proxies regenerate; the v1 files stay in the cache folder until "remove all proxies". 378 tests, 0 failed (CLT wrapper, 2026-10-16) |
| Frame-exact clip timing, schema 11 (branch `plan/10bit-vlog-color`) | PASS: unit and integration (55 of 240 output frames were wrong on the old code, 0 now), and G6 on the composition with real `P1107157` (frames 33 000–33 239). 392 tests, 0 failed (CLT wrapper, 2026-10-16). Through-export G6 and the UI walkthrough are NOT VERIFIED |
| Source color detection (branch `plan/10bit-vlog-color`) | PASS: unit tests (Panasonic XML, H.264 SPS bit depth and chroma, tag fallback) and real S5 files. `P1107158` reads as V-Log / V-Gamut, 10-bit 4:2:2, full range, despite its BT.709 tags. `P1107172` reads as Rec. 709, 8-bit 4:2:0, video range. Detection only: rendering V-Log comes with the compositor and the LUT/OCIO tasks |
| Video color kernels (branch `plan/10bit-vlog-color`): Y'CbCr decode, 10-bit 4:2:2 encode, fit | PASS: 13 GPU/unit tests against Double references (four of them also fail when the siting or range math is broken on purpose), and a real UHD V-Log frame within 0.25/1023 of the equations at a median 1.87 ms GPU time (release, M1). Not yet used by playback |
| Custom video compositor (branch `plan/10bit-vlog-color`) | PASS: 433 tests, 0 failed (CLT wrapper, twice). Neutral 10-bit footage keeps all 1024 levels, a graded frame is within a mean of 0.3/255 of the old Core Image path, rotation matches AVFoundation, mixed sizes/formats/proxies cut on exact frames, gaps are black, and a 50-seek storm leaves nothing pending. UHD on the M1: neutral 75–79 fps, graded 21–36 fps, graded 1080p proxy 83–136 fps. **NOT VERIFIED:** on-screen playback in the app, the cancel path, graded 4K memory (+770–860 MB over idle, above the 600 MB budget) |
| Proxy frame timestamps (found 2026-10-16) | FIXED on `plan/10bit-vlog-color` only: proxies were written at timescale 600 and drifted off frame boundaries. `feat/video-proxies` (PR #14) still has the bug |
| Distribution signing and notarization | NOT VERIFIED |

## Open problems

1. **Black edited canvas (open bug).** After Export → New → Open → Photo, the edited preview can stay black although the render and histogram are valid; switching Original → Edited restores it. Cause not established. Publication-during-update faults and stale-completion races were fixed separately and are covered by tests. Evidence: [workspace transition](archive/WORKSPACE_TRANSITION_2026-10-10.md), [preview trace](archive/PREVIEW_TRACE_2026-10-09.md). Plan: [preview-reopen-recovery](../plans/active/preview-reopen-recovery.md). In progress on branch `metal-canvas` ([plan](../plans/active/metal-canvas.md)): the photo is drawn by a Metal view instead of SwiftUI `Image`. The Metal view is now merged (PR #9). On 2026-10-14 the release build of `main` with tracing on did **not** reproduce the black canvas in seven attempts (fresh launch → Add Files in Place → Photo; Library → Photo; project Save → New → Open → Photo ×5; every trace shows renderer, publish and a Metal draw with `image=true`, command buffer status completed). The bug is therefore still **not reproduced and not explained** on `main`; whether Metal removes it is **NOT VERIFIED** (not enough runs to claim). The Metal view now traces skipped draws and command-buffer status under `PME_PREVIEW_DIAGNOSTICS=1`, so the next occurrence will show whether the draw was skipped, failed on the GPU, or succeeded. `PME_SystemImageCanvas=1` compares against the old canvas.
2. **Selection quality.** Subject edge matting (hair wisps, spill) is implemented on branch `selection-quality` but not verified in the app. Fine edges and shaded sky gaps are weak, group members can be missed, and recovered masks spill at edges. See [selection quality](archive/SELECTION_QUALITY_2026-10-08.md).
3. **Not yet built:** reflection and broader lighting controls, color and luminance range masks, RAW+JPEG pairs, undo for ratings, persistent export recipes, output sharpening, P3, IPTC/copyright, watermark.
4. **`EditorStore` is too large** (about 1,450 lines, 100+ state properties). Splitting it is overdue.

## Next

Resolve the black canvas, then the selection-quality items, then run the genuine single-shoot acceptance and agree performance thresholds. Direction beyond that is in [ROADMAP](ROADMAP.md).
