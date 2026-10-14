# Project Review and Suggested Next Steps

**Date:** September 28, 2026  
**Reviewed revision:** `0087443` — Add continuous wheel zoom to photo editor  
**Overall assessment:** Yellow — substantial photo editing capability, with delivery and production validation still incomplete.

**Implementation follow-up:** Next step 1 is now implemented: original protection, import ownership/cancellation, persistent save failures, and bounded undo/history. The full automated suite and isolated brush benchmarks pass. See [Reliability Pass](RELIABILITY_PASS_2026-09-28.md) for evidence and remaining real-shoot/UI acceptance. The review findings below describe the initial `0087443` snapshot.

## Summary

Perception Media Editor has moved well beyond the video foundation described in the README. It now supports most of the manual workflow from verified card import through culling, RAW development, presets, and local adjustments. The appropriate next milestone is a reliable, complete photo job: import a 100–200-frame Lumix S5 shoot, select and edit the keepers, deliver them in one batch, and reopen the project with all final edits intact.

The largest workflow gap is delivery. Export currently processes one selected photo at fixed full resolution, with sRGB JPEG at 92% quality or PNG. Healing is also absent despite the roadmap identifying it as a tool used on almost every shoot. Address reliability risks first, then bring a small batch-export milestone forward before completing every advanced mask feature. Keep video development deferred under the existing photo-first direction.

## Review scope and verification

Reviewed the roadmap, architecture, historical design/QA reports, recent commits, Swift package and CI configuration, and implementation/test coverage for ingestion, persistence, culling, RAW rendering, masks, zoom, presets, export, and workflow agents. The checkout was clean at the start of the review.

| Check | Result / limitation |
| --- | --- |
| Standard test/build script | **Failed:** 205/206 tests passed in 23.54 seconds. The brush-cache test's initial render took 2.18 seconds against a 2-second limit. The script stopped before its separate app-build step. |
| Isolated failing-test rerun | **Passed:** `manyStrokesAreCachedSoUnrelatedRendersAreCheap` completed in 0.526 seconds. This suggests sensitivity to concurrent load; it does not erase the full-suite failure. |
| Standalone debug app build | **Passed:** `swift build ... --product PerceptionEditor` completed after the test run. Release packaging/signing was not rerun. |
| Real RAW tests | All five passed locally, using the available S5 fixture. |
| Deterministic source reviewers | `./scripts/agent-review.sh all` completed. These are source searches and a diff check, not independent functional QA. |
| Repository formatting | `git diff --check` passed before report creation. |
| Test inventory | 206 `@Test` declarations across 16 test files; actual execution count is reported separately. |
| Target hardware validation | No new full-shoot benchmark on the specified 8 GB M1 MacBook Air. |
| Current UI acceptance | No new hands-on acceptance pass of the latest masks/zoom build. Historical video QA is insufficient to establish current photo readiness. |

Verification ran on Apple Silicon with macOS 26.6.2 and Swift 6.3.3, rather than establishing the macOS 15/Swift 6.1 compatibility floor. The first sandboxed invocation could not write to an existing Swift build-cache file; the approved retry compiled and ran the suite. Logs are in `.build/project-review-tests-2026-09-28.log`, `.build/project-review-brush-retest-2026-09-28.log`, and `.build/project-review-build-2026-09-28.log`.

This is a project and source review. The risks below are supported by implementation inspection; scenarios that were not reproduced are labeled accordingly. No application code was changed.

## Current capability

| Area | Assessment | Remaining work |
| --- | --- | --- |
| Foundation | Actor-based photo rendering, metadata-only import, bounded working-image caches, atomic project saves, and automated tests/CI are implemented. | Measure the combined memory footprint and recovery behavior across a real shoot. |
| Import and culling | Verified copies, optional backup, dated shoot folders, flags/stars/labels, filtering, compare, multi-selection, and focus checks are implemented. | Culling undo, RAW+JPEG pairing, interruption and project-lifecycle cases. |
| RAW development | Kelvin/tint, detail/noise controls, lens correction, curves, HSL, and full-resolution focus view are implemented. | Neutral-gray eyedropper, auto tone/white balance, broader image-quality validation. |
| Presets and history | Grouped presets, categories, import/export, copy/paste/sync, selection-wide application, and session history are implemented. | Bounded undo storage; clarify that history does not survive reopening. |
| Local edits | Linear/radial gradients, brush/erase, overlay, geometry mapping, and wheel zoom/pan are implemented. | Healing/clone, range masks, subject/sky selection, current UI QA. |
| Delivery | Single-photo full-resolution JPEG/PNG export is implemented. | Batch queue, recipes, resize, naming, sharpening, metadata, watermark, and optional P3. |
| Workflow agents | Local metadata checks and reversible adjustment-copy proposals are implemented. | Actual focus, eyes, subject, and near-duplicate analysis remains future work. |
| Video | Timeline playback, clip color, waveforms, volume, and fades remain available. | Export, mixed-orientation framing, advanced audio, proxies/LUTs, and broader compatibility. Resume after the photo gates. |

## Reliability issues to address first

### Restore a dependable automated gate

The full test suite currently has a measured timing failure at `Tests/PerceptionEditorTests/MaskTests.swift:379`. Its isolated rerun passes. Investigate concurrent render load and shared-cache behavior; separate controlled performance benchmarks from correctness/cache-reuse tests. The current assertion for the cached render (`cached < first + 0.05`) also does not require a substantial speedup. Add meaningful reuse evidence and calibrated benchmarks rather than simply increasing the threshold. Treat the full suite as failing until the underlying gate is resolved.

### 1. Enforce original-file protection at export — high priority

`EditorStore.exportSelectedPhoto()` accepts the save-panel destination and passes it to `PhotoRenderer.export()`. The renderer writes directly to that URL. Neither layer checks whether the destination identifies the selected source or another original referenced by the project. The default `_edited` filename reduces accidental collisions, but does not enforce the non-destructive contract.

**Next step:** Reject destinations that resolve to any protected source file, including path aliases; render into a temporary sibling and replace the intended output only after success. Verify using disposable JPEG/PNG fixtures and a failed-export case. This overwrite scenario was not exercised on original media during this review.

**Evidence:** `EditorStore.swift:722`, `PhotoRenderer.swift:293`.

### 2. Bind background import work to its project — high priority

Card scanning runs in an untracked task; `cancelIngest()` only cancels the worker assigned after scanning. Each file callback calls `addIngestedFile()` on whichever project the store currently holds. New/Open/reset/load have no ingest guard or operation identity. The import sheet blocks interactive dismissal, which helps the normal UI path, but the store itself does not enforce project ownership or stop stale callbacks.

**Next step:** Give an import a project/operation identity; invalidate old callbacks on replacement; track cancellation from scanning through copying and backup. Verify Stop during scanning, project replacement during import, and final-file callbacks before the final project save. Cross-project contamination is a source-level risk, not a reproduced UI defect here.

**Evidence:** `EditorStore+Ingest.swift:108`, `:150`, `:164`; `EditorStore.swift:619`, `:690`.

### 3. Make autosave failures persistently visible — high priority

Autosave failure sets a transient status message. The status bar displays an unsaved indicator only when `projectURL == nil`, and its status dot remains green. A saved project on a disconnected or unwritable drive can therefore lose its visible failure message after another action while changes remain unsaved.

**Next step:** Track save state independently of general status text; show pending/failed saves for existing projects, offer retry/Save As, and test drive disconnection and write failure. Atomic saves and the save-before-New/Open/Quit checks are existing strengths to retain.

**Evidence:** `EditorStore+Culling.swift:398`; `RootView.swift` status bar.

### 4. Bound undo memory across long editing sessions — medium priority

Each adjustment undo step stores the project's entire adjustment dictionary, with no stack limit. Per-photo history has a 100-entry cap, but it is separate from undo. Swift value sharing reduces some copies; many changes and brush edits can still retain substantial prior state. This is a plausible pressure point on an 8 GB machine, not a measured memory failure.

**Next step:** Measure a 200-photo session with repeated brush edits and sync operations; use changes for affected assets and an explicit undo budget. Profile simultaneous focus decoding, previews, thumbnails, and export rather than only each cache in isolation.

**Evidence:** `EditorStore.swift:313`; `EditorStore+Presets.swift:92`; `AdjustmentGroups.swift:157`.

## Recommended implementation order

| Order | Deliverable | Why now | Acceptance gate |
| --- | --- | --- | --- |
| 1 | Reliability fixes and a current photo QA baseline | Protect originals and project edits before increasing throughput. | Automated gate passes reliably; export cannot target originals; failed saves remain visible; cancelled/stale import callbacks cannot change another project; 200-frame baseline recorded. |
| 2 | Batch delivery MVP | Removes the largest repetitive step in a normal job. | Export a selected/picked set sequentially; recipe specifies JPEG quality, long edge, and naming; progress/cancel and per-file failures are visible; no collisions or partial completed outputs. |
| 3 | Spot healing and clone | A stated everyday dependency for replacing Lightroom. | Non-destructive source/target data survives save/reopen; preview/export agree through rotation/crop; one gesture is one undo step. Start with manual clone/spot repair before content-aware repair. |
| 4 | Finish frequent Develop and Cull actions | Reduces correction time and accidental culling changes. | Neutral-gray eyedropper, undo/redo for flags/stars/labels, and explicit RAW+JPEG pair behavior. Add reversible auto tone/WB after image-quality checks. |
| 5 | Complete delivery recipes and selective masks | Adds professional output control and common selective-editing tools. | Output sharpening, metadata/copyright, watermark, optional P3; color/luminance ranges; then subject/sky masks with manual refinement. |
| 6 | Smart culling | Useful after manual editing and delivery are dependable. | Focus/closed-eye/near-duplicate scores measured against a manually reviewed fixture set, with advisory results and overrides. |
| 7 | Resume video | Follows the existing roadmap decision. | Start with output/export and correct per-clip framing; evaluate actual S5 footage before expanding titles, transitions, or mixing. |

The batch-delivery MVP is a recommended change to roadmap sequencing, not a claim that the current roadmap already schedules it before advanced masks. Add watermark/IPTC/P3 after the queue, naming, and resizing work correctly.

Refactor incrementally alongside orders 1–2: extract project persistence/lifecycle and the export queue first, then isolate timeline state. The main `EditorStore.swift` remains 1,300 lines despite useful photo extensions. Preserve its public facade and existing regression tests during extraction; a broad rewrite would delay the workflow milestone.

## Production validation gate

Run one real 100–200-file S5 shoot on the 8 GB M1 Air, with representative portraits, high ISO, difficult white balance, and recoverable highlights. Record import throughput, cold/warm cull latency, slider/mask response, first 100% decode, export time, peak memory, and memory after leaving focus/export. Establish measured budgets before calling performance complete.

Exercise save/reopen, disk disconnection, missing originals/relink, interrupted import/export, name collisions, repeated undo/redo, and masks under crop/rotation/zoom. Compare final exports with previews and inspect skin tones, highlights, noise, and mask edges. Include mouse-wheel and trackpad behavior, keyboard focus, small-window layout, and accessible control labels in the UI pass.

Five real-RAW tests are conditional on local samples. `RawSample` defaults to `/Volumes/ExSSD1/110_PANA` and selects the first sorted RW2; CI does not configure that directory. Add a small licensed representative fixture set or a required camera-fixture run that reports skips explicitly. A green synthetic-image suite alone cannot establish S5 color quality, camera breadth, or whole-shoot performance.

## Update project documentation and status

- Make the photo-first direction and current milestone consistent in README, roadmap, UI status, and bundle metadata. README says V0.3 video foundation; the UI says V0.4 Library + Culling; bundle metadata says 0.3.4 build 8; project schema is 6. Schema and app versions serve different purposes, but the current capability label should be consistent.
- Reconcile stale V0.2/V0.3 checklist items with the newer phase checklist. RAW controls, multi-selection, and sync are implemented but remain unchecked in the legacy section; the Phase 1 focus item is still unchecked despite Phase 2 completion.
- Update architecture language that still calls video a placeholder/planned engine and says full-resolution decoding occurs only for export. The focus view also decodes full resolution.
- Add current photo acceptance evidence. Existing milestone/QA reports describe older video increments and should remain historical records.

## Immediate next milestone

**Reliable Photo Delivery:** close original protection, import ownership, and save-state gaps; establish the 200-frame performance baseline; then deliver a sequential batch JPEG queue with resizing, naming, and reusable recipes. That milestone makes the project substantially more useful for a complete photography job while creating a sound base for healing and advanced masks.
