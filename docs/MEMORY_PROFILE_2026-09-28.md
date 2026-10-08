# Memory profile — 28 September 2026

## Measurements on this Mac

Apple M1 MacBook Air, 8 GiB unified memory, macOS 26.6.2.
The release app was not running before this check. A fresh launch with an empty
project measured **36 MiB physical footprint**, with a **71 MiB launch peak**, using
macOS `footprint`.

UI automation stalled in the file picker. Loaded-photo measurements therefore
come from an isolated Swift Testing process calling the production photo loaders
and renderers, not from the complete SwiftUI app. The process retained 16 thumbnails,
10 embedded culling previews, four working RAW sources, and the latest before/after
images. It used the 16 distinct Lumix S5 RW2 files in `/Volumes/ExSSD1/110_PANA`.
The focus viewport was 1800 × 1200 pixels. Export was one full-size neutral JPEG.

| Diagnostic stage | Physical footprint |
| --- | ---: |
| Test process baseline | 5.5 MiB |
| 16 thumbnails | 23 MiB |
| Plus 10 culling previews | 23 MiB |
| Plus four RAW working sources and before/after | 800 MiB |
| Plus 100% RAW focus | 2,033 MiB |
| Immediately after leaving focus | 2,024 MiB |
| After clearing focus context caches and waiting one second | 409 MiB |
| After one full-size JPEG export | 1,324 MiB |
| After clearing all context caches and waiting one second | 480 MiB |

The first run without explicit cache clearing measured 786 MiB for editing,
2,021 MiB for focus, and 1,324 MiB after export. These repeat observations support
the magnitude of the problem. The recorded peak in the second run was 2,033 MiB.

Physical footprint includes memory charged to the process beyond ordinary resident
CPU pages, including compressed memory and graphics allocations. For example,
the focus stage had only 144 MiB reported resident memory despite its 2,033 MiB
footprint. RSS alone would substantially understate the cost on this Mac.

The culling images were retained without a real on-screen display pass; their small
footprint here is not a measurement of the fully displayed culling workspace.
These results are not a whole-app ceiling. SwiftUI, displayed image backing,
mask/healing workloads, rapid navigation, and a 200-photo session need separate
profiling. Do not add the thumbnail dictionary counts together: several dictionaries
hold references to the same images.

## Suggested next steps, in order

1. **Release Core Image resources at lifecycle boundaries.** Call `clearCaches()`
   after full-resolution focus is released and after export completes. Consider
   idle renderer cleanup and a memory-pressure handler. The temporary experiment
   reduced post-focus footprint by about 1.6 GiB and post-export footprint by about
   844 MiB. Clearing caches should happen after work finishes, rather than on every
   slider frame, because it can require GPU resources to be allocated again.
   Core Image cache clearing also performs resource garbage collection, so the
   observed saving should not be attributed exclusively to one context's buffers.

2. **Set and profile render-context memory budgets.** Each preview, thumbnail,
   focus, and export renderer creates its own `CIContext`. The local Apple SDK
   documents `CIContextOption.memoryTarget` (SDK constant `kCIContextMemoryLimit`)
   as a render-task allocation target in MB,
   with a performance tradeoff. This is available below the project's macOS 15
   deployment floor. Tune it against actual rendering speed and peak footprint;
   it is not a limit on the whole app or all RAW-decoder allocations. Retain
   half-float working precision for RAW highlight recovery.

3. **Bound thumbnail memory and its owners.** `ThumbnailCache.memory`,
   `EditorStore.photoThumbnails`, and `diskThumbnailMemo` currently retain images
   without a byte budget. Use one coordinated byte-budgeted cache and retain only
   visible/nearby images in the UI. Preserve the disk cache for fast reloads.
   At 420 × 280 RGBA8, 200 decoded thumbnails alone are about 90 MiB; larger shoots
   continue growing under the current design.

4. **Bound culling work in flight.** The completed cache is limited to 10 previews,
   but `prefetch` launches detached decodes without a concurrency cap. Coalesce
   rapid navigation, prioritize the current photo, cancel stale requests, and
   prevent cleared caches from being repopulated by old work. A smaller 6-preview
   cache could save roughly 38–67 MiB in decoded image backing, depending on size,
   at the cost of more reloads when navigating backward.

5. **Profile the complete app after these changes.** Measure a distinct 200-photo
   shoot through culling, edits, brushes, repeated zoom/pan, exports, and project
   replacement. Record peaks and post-operation settling, and check render latency
   and exported image equivalence. Treat roughly 0.8 GiB editing and 2 GiB zoom as
   current diagnostic observations, not promised whole-app bounds.

The renderer already limits working sources to four, reduces preview resolution,
disables intermediate-result caching, and releases its full-resolution source on
zoom exit. Undo/history retention was bounded in the reliability pass. The new
measurements show that clearing the source reference alone does not immediately
release the larger rendering-resource footprint.

## Reproducibility and changes

Logs: `.build/ram-profile.log` and `.build/ram-profile-cache-release.log`.
The diagnostic sampled `task_info(TASK_VM_INFO)` physical footprint and, on the
second run, its peak. Both isolated runs passed. A temporary `clearCaches()` hook
was added only for the second experiment, then the exact original renderer bytes
were restored automatically. The temporary test and project file were removed.
The release app bundle was not rebuilt or optimized during this check.

## Follow-up

These suggestions were implemented in version 0.3.5, build 10. See
[Memory Optimization](MEMORY_OPTIMIZATION_2026-09-28.md) for the current behavior,
verification, and measured improvements. The measurements above describe the earlier build.
