# Performance targets and measurement

The target workload is a 100–200-file Lumix S5 RW2 shoot on an 8 GB M1 MacBook Air. Smooth culling and responsive editing matter more than maximizing concurrent decodes. A target is not a measured pass.

## Existing engineering constraints

- Editing working copies are capped at 2560 px and four cached sources; full-resolution work is reserved for 100% focus and export.
- Culling decode concurrency is bounded, stale queued work is replaced, and thumbnail memory has a shared budget.
- Core Image allocation targets and undo/history budgets limit individual owners; they do not cap the whole process. Full-resolution focus/export normally use 128 MiB, with a lazy 256 MiB context for active healing because the observed 24 MP RAW color-matching render needs more than 128 MiB. That context is released at operation/cache lifecycle boundaries.
- Real-RAW memory evidence and limitations are recorded in [MEMORY_PROFILE_2026-09-28.md](archive/MEMORY_PROFILE_2026-09-28.md) and [MEMORY_OPTIMIZATION_2026-09-28.md](archive/MEMORY_OPTIMIZATION_2026-09-28.md).

## Video proxies

| Operation | Target | Measured |
|---|---|---|
| Proxy generation, S5 UHD 4:2:2 H.264 | ≥ 1.2× realtime (28.8 fps at 23.976) | 72.0 fps (about 3.0×) at `.utility` QoS, 10 s trim, debug build, after the 2026-10-16 full-range fix (reader scaling + VideoToolbox range conversion); 79.6 fps release. Before the fix: 68.5 fps debug (71.4 fps at `.userInitiated`) |
| Proxy decode (ProRes 422 Proxy, 1080p) | ≥ 120 fps | 345 fps (evaluation probe) |

UI responsiveness during generation is NOT VERIFIED.

## Video compositor (branch `plan/10bit-vlog-color`)

**Caveat (found 2026-10-17):** the external SSD holding the clips (a Samsung T7) was linked at USB 2.0 (480 Mb/s, about 38 MB/s) through a USB-C adaptor's hub for every video measurement below. That bounds reading `P1107157` (151 Mb/s) to about 47 fps, so the decode ceilings and the G1 export numbers were the link, not the Mac. The re-runs from the internal disk are in the export table and under "Source color through OpenColorIO". See the [Apple Log record](decisions/2026-10-17-apple-log.md).

Lumix S5 `P1107157.MOV`, a 10 s UHD V-Log passthrough trim, `RealVideoCompositorTests`, release build, 8 GB M1, one case per process (`PME_COMPOSITOR_CASE`). Speeds vary 20–40% between runs on this passively cooled Mac.

| Case | Speed | App footprint |
|---|---|---|
| 4K original, neutral, preview (half float) | 75–79 fps | 12 → 243 MB |
| 4K original, neutral, export (`x422`) | 68–80 fps | 12 → 340 MB |
| 4K original, graded, preview | 21–36 fps | 12 → 876 MB |
| 4K original, graded, export | 23–34 fps | 12 → 785 MB |
| 1080p proxy, graded, preview | 83–136 fps | 19 → 232 MB |
| 4K original, Panasonic V-Log to V-709 source color, preview | 78.7 fps | 17 → 567 MB |
| 4K original, Panasonic V-Log to V-709 source color, export | 79.2 fps | 17 → 474 MB |

The grade is the heavy test chain (exposure, contrast, highlights, shadows, temperature, tint, vibrance, saturation, curves, HSL, sharpness, vignette). It costs about 20–30 ms per 4K frame, so graded 4K originals sit at or below real time; playback should use proxies. Graded 4K adds about 770–860 MB over idle, above G7's 600 MB export budget; the likely cause is Core Image's half-float intermediates at 4K. The decoder process (`VTDecoderXPCService`, about 250 MB) is not included. Both are open work for Tasks 5 and 11.

## Timeline export (branch `plan/10bit-vlog-color`)

`RealVideoExportTests.uhdExportThroughput` under `scripts/profile-video.sh`: 60 s (1 439 frames) of `P1107157` UHD V-Log, Panasonic's V-Log to V-709 LUT, exported at UHD, release build, 8 GB M1. Memory is the test process plus `VTDecoderXPCService`, sampled twice a second.

| Format | Speed (G1 target 38 fps) | Size | Peak over idle (G7 limit 600 MB) |
|---|---|---|---|
| ProRes 422 HQ, source and output on the T7 at USB 2.0 | 8.8 fps (limited by writing 5.1 GB at about 38 MB/s) | 5.13 GB | about 1 500 MB (app 1 003, decoder 539) |
| HEVC Main10, T7 at USB 2.0 | 34.4 fps | 363 MB | about 1 500 MB (app 994, decoder 535) |
| ProRes 422 HQ, internal disk (2026-10-17) | **52.1 fps** | 5.13 GB | 1 554 MB (app 1 010, decoder 550) |
| HEVC Main10, internal disk (2026-10-17) | **49.0 fps** | 363 MB | 1 594 MB (app 1 045, decoder 551) |

G1 (export) PASSES from the internal disk. G7 (export) FAILS. Task 11 added the instrumentation to work on the memory overrun but did not reduce it.

## Source color through OpenColorIO (branch `plan/10bit-vlog-color`)

Same harness as the compositor table (10 s of `P1107157`, release, one case per process).

| Case | Without ACES | With ACES (V-Log → ACES 2.0 Rec. 709) | App footprint with ACES |
|---|---|---|---|
| 4K original, neutral, preview | 78.6 fps | 35.7 fps | 12 → 494 MB |
| 4K original, neutral, export | — | 35.9 fps | 12 → 490 MB |
| 4K original, graded, preview | 25.1 fps | 15.9 fps | 12 → 1 231 MB |
| 1080p proxy, graded, preview | 94.6 fps | 49–50 fps | 23 → 320 MB |

The ACES 2.0 output transform costs about 15 ms per 4K frame on the M1.

From the internal disk, the S5 4K V-Log H.264 decode ceiling is **82 fps** (2026-10-17; Task 0's 47 fps was the USB 2.0 link). iPhone 15 Pro Apple Log ProRes 422 HQ 4K decodes at 105–110 fps, and runs through the compositor at 99 fps.

## Apple Log, gate G12 (branch `plan/10bit-vlog-color`)

Measured 2026-10-17 on the base 8 GB M1 from an internal-disk copy of `IMG_0001` (4K Apple Log ProRes 422 HQ), release build. Bar: UHD export through the compositor at 85% of the internal-disk decode ceiling (about 90 fps), proxy preview with 0 dropped frames over 60 s, and G7's memory limits.

| Case | Result |
|---|---|
| 4K original, neutral, preview | 48.7 fps (peak 521 MB) |
| 4K original, ACES, preview | 29.7 fps (peak 547 MB) |
| 4K original, ACES, compositor export path | 23.0 fps (peak 529 MB) |
| 1080p proxy, ACES, graded, preview | 55.0 fps (peak 302 MB); proxy generation 240 frames in 10.8 s |
| UHD ProRes 422 HQ export, 608 frames, Panasonic-style LUT | 10.8 fps (56.5 s, 2.16 GB) |
| Proxy playback, 25 s x 3 runs, scopes on | 0 of 600 frames dropped in each run; GPU median 7.41, p99 14.30, max 21.56 ms; growth 18.6 MB |
| G7 export | +1 291 MB over idle (limit 600) |
| G7 playback | +445 MB over start of playback (limit 350) |

**G12: FAIL.** Export reaches 10.8 fps and the compositor alone reaches 23-49 fps, against a bar of about 90 fps. G7 memory fails for export and playback. Proxy preview dropped 0 frames, but over 25 s x 3 runs, not the 60 s the gate names, so that part is NOT VERIFIED at 60 s. The earlier "compositor 99 fps" was the decode-only path; the full compositor with the colour kernels is slower. The runs were short (240 frames) and the machine swapped (245 580 pages during export), so the numbers are likely pessimistic. Tuning is left for the owner to direct.

## Proxy playback, gates G1 and G7 (branch `plan/10bit-vlog-color`)

`PME_PROFILE=playback scripts/profile-video.sh` (`RealVideoPlaybackTests`): a 1080p proxy of 60 s of `P1107157` with the golden grade, source color and scopes, played by AVPlayer in real time 10 times, release, 8 GB M1. Targets: G1 0 dropped frames and GPU ≤ 12 ms per frame; G7 ≤ +350 MB from the start of playback (app plus decoder) and ≤ 20 MB growth over 10 runs.

| Source color | Dropped | GPU per frame | Over start of playback | Growth over 10 runs |
|---|---|---|---|---|
| Panasonic LUT | 6 of 14 380 | median 5.3, p99 10.9, max 23.7 ms | +513 MB (app 481, decoder 182 peak) | 35 MB (330 → 365 MB by run 3, then flat) |
| Panasonic LUT, internal disk, heavy swapping (213 000 pages) | 8 of 14 380 | median 5.4, p99 13.1, max 16.0 ms | +691 MB (app 510, decoder 354 peak) | 1.2 MB |
| ACES 2.0 | 1 of 14 380 | median 6.4, p99 13.4, max 29.0 ms | not measured from playback start | 2.9 MB |

G1 (playback) and G7 (playback) FAIL. Scopes run at 13.7 Hz in both.

## Scopes (branch `plan/10bit-vlog-color`)

Gate G9, `RealVideoScopeTests` with `PME_VLOG_SHORT=P1107158.MOV`, release, 8 GB M1, frames pulled at 24 fps through the compositor. Target: at least 10 updates a second, at most 2 ms GPU per update at 1080p.

| Measure | Result |
|---|---|
| Update rate during playback | 14.6 Hz (every second frame) |
| Analysis (waveform + vectorscope, 512 × 288 capture) | 0.67 ms GPU median |
| Capture downsample in the compositor | 0.43 ms at 1080p, 1.46 ms at UHD |

## Acceptance workload

Run a distinct 100–200-photo shoot through import, culling, Develop, masks, focus, export, save/reopen, and cache release on the target Mac. Record hardware and OS, sample count, file sizes, cold/warm cull latency, slider/mask response, first focus decode, export time, peak process footprint, and footprint after leaving focus/export. Check output pixels and failure recovery. `scripts/profile-memory.sh` is an isolated renderer diagnostic, not a full SwiftUI app measurement.

Do not invent a pass/fail number from one isolated sample. Before a feature milestone claims performance completion, set a measured threshold for its specific operation and compare a baseline with the candidate build under the same workload. Report **NOT VERIFIED** when the representative media or interactive test is unavailable.

The [October 7 target-Mac validation](archive/WORKFLOW_VALIDATION_2026-10-07.md) records a 100-distinct-S5-photo varied-library displayed run and a separate fresh-process renderer diagnostic. It does not substitute for the genuine single-shoot workload, broad visual acceptance, or an agreed threshold/baseline comparison.
