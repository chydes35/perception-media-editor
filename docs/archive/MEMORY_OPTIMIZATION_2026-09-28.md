# Memory optimization — 28 September 2026

## Implemented

- Core Image rendering runs inside autorelease pools. Exiting 100% focus, finishing
  or failing an export, and replacing a project release disposable rendering caches.
- Core Image allocation targets are **256 MB for editing**, **128 MB for focus and
  export**, and **32 MB for thumbnails**. These are allocation targets, not hard
  process-memory ceilings. Half-float RAW working precision and export dimensions
  remain intact.
- Photo/video thumbnails share **one 32 MiB LRU cache**. The store publishes a
  completion revision instead of retaining additional image dictionaries. Evicted
  thumbnails reload from disk; disk keys now use sorted JSON so their filenames
  are deterministic. JPEG encoding uses the bitmap directly, avoiding TIFF copies.
- Culling retains six previews and permits at most two decodes in flight. Navigation
  replaces the queued neighborhood. Cancelled system decodes retain their slots until
  they finish; their results cannot repopulate a cleared cache or replace a relinked
  asset. Failed decodes do not retry indefinitely. Compare requests share the queue
  with the selected photo and its neighbors.
- macOS memory-pressure notifications release thumbnails, culling and brush caches,
  trim working sources, and reclaim render-context resources. The visible image and
  project edits remain available. The observer is cancelled when its store is released.

## Measured on the 8 GiB M1 MacBook Air

The same 16 distinct Lumix S5 RAW samples were exercised in an isolated diagnostic
process. For comparability, it deliberately retained ten embedded culling images,
though the app now caches six. Measurements use the process's physical footprint,
including compressed and graphics memory charged to it.

| Stage | Earlier diagnostic | Optimized diagnostic |
| --- | ---: | ---: |
| Four working sources + before/after | 786–800 MiB | 687 MiB |
| 100% RAW focus, sampled after rendering | 2,021–2,033 MiB | 781 MiB |
| After leaving focus | 2,012 MiB | 408 MiB |
| After full-size JPEG export | 1,324 MiB | 567 MiB |
| Workflow peak | 2,033 MiB recorded in earlier cache experiment | 1,257 MiB |

Optimized latency observations:

- Four cold working sources with before/after: 5.14 seconds total.
- Warm adjustment preview: median 21.3 ms, maximum 32.3 ms across 15 renders.
- Initial full RAW focus: 840 ms.
- Focus pan: median 8.7 ms, maximum 9.0 ms across ten pans.
- Full-size JPEG export: 674 ms.
- RAW preview with white balance, exposure, contrast, highlights and shadows:
  **zero channel difference** against an unbudgeted renderer across all output pixels.

These are sampled observations, not latency guarantees. Multiple allocation targets
were profiled in separate sequential processes. A uniform 128 MB target produced a
lower observed peak (845 MiB) but a longer cold-load run; the selected configuration
keeps editing responsive while reducing focus/export allocations. System load, warm
GPU resources and memory pressure affect both latency and footprint. The earlier
and optimized scripts also differ in pan/slider repetitions and settling delays;
this is a practical comparison, not a controlled performance claim about each change.

The full SwiftUI app, fully displayed culling images, heavy masks/healing, and a
complete 200-photo shoot still require a combined UI profile. These measurements
are not a whole-app RAM ceiling. Visible SwiftUI image backing and cache bookkeeping
are additional to the thumbnail cache's accounted bitmap budget.

## Verification and reproduction

Run `./scripts/test.sh` for the normal correctness suite. Run
`./scripts/profile-memory.sh` alone for the opt-in memory, latency, and RAW pixel
comparison; the default sample folder is `/Volumes/ExSSD1/110_PANA`. Override it with
`PME_RAW_SAMPLE_DIR`. Target experiments can use `PME_RENDER_MEMORY_TARGET_MB` and
`PME_FULL_RES_MEMORY_TARGET_MB` (`none` disables the respective target).

Six new correctness regressions exercise thumbnail byte eviction, disk reload,
oversized-image handling, pressure cleanup, rapid culling navigation, cache clearing,
and failed decodes. Temporary removal of eviction/stale-result protection caused
three regressions to fail with 11 assertions. The exact optimized sources were
restored, and the six memory tests passed. Reverting only sorted JSON keys separately
reproduced the disk-cache failure with two failed reload assertions; the exact source was
restored before the full suite. The complete suite passed: **230 executed tests and
three opt-in benchmarks skipped** (233 reported total), including all five real-RAW
tests. Culling tests use explicit asynchronous gates and run serially within their
suite so parallel rendering work cannot expire a simulated decoder.

Logs are under `.build/`: `memory-profile-final.log`, `memory-profile-128.log`,
`memory-profile-256.log`, `memory-profile-64.log`, `memory-profile-none.log`,
`memory-causal-red.log`, `memory-causal-green.log`, `thumbnail-key-causal-red.log`,
`memory-full-tests.log`, `cull-final-causal-red.log`, `cull-final-causal-green.log`,
and `memory-release-build.log`. The first four target experiments used a uniform
editing/focus/export target; the final profile uses the shipped mixed targets.

The local release bundle is version **0.3.5, build 10**. Restart the app to load it.
