# Reliability Pass — September 28, 2026

Implements next step 1 from the project review. App version remains 0.3.4; the local bundle build advances to 9. Project schema remains 6 because these changes do not add persisted project fields.

## Delivered

- **Protected originals:** export rejects the source and every other original referenced by the project, including symbolic links, parent-folder aliases, and hard links. Protection is checked before rendering and again before publication. JPEG/PNG exports are rendered into a temporary sibling and renamed into place only when complete; failures clean up the temporary file and preserve an existing output.
- **Import ownership and cancellation:** an operation identity and project generation guard scan/copy/progress/completion callbacks. Cancellation works before or during scanning, copying, and backup. Project replacement invalidates old callbacks, including when reopening the same project ID. Reference-file imports also retain their original project generation. A new import waits for a cancelled copy worker to close and clean up its partial files.
- **Complete final import saves:** the returned verified-file list is reconciled synchronously before the final autosave, so independently queued file callbacks cannot leave the saved project incomplete. Late callbacks are ignored after completion. New/Open are disabled while importing; Quit asks the user to stop the import first. The stop button now says **Stop Import**, matching cancellation of an incomplete copy.
- **Persistent save state:** unsaved, pending, saved, and failed states are independent of general editing status. A failed save leaves the last-saved snapshot intact and remains visible with **Retry Save** and **Save As** actions. A successful retry or Save As clears the failure.
- **Bounded undo:** undo/redo retain changes for affected photos, rather than snapshots of every photo. They share a 100-step / 32 MiB estimated retention budget. Session history has its existing 100-entry per-photo limit plus a 16 MiB shoot-wide estimated retention budget. Older entries are discarded when budgets are reached. A single edit exceeding the undo budget clears the undo chain; the edit itself remains applied. Undo does not reintroduce adjustment records for removed photos.
- **Dependable brush checks:** correctness tests require exact bitmap reuse and verify continuation against a fresh raster. Timing tests run separately with private caches and a monotonic clock. The 2-second initial-render and 100-ms appended-point limits remain; exact cache reuse has a 50-ms limit.

Retention budgets conservatively account for settings, curves, masks, and brush points. They are not measured limits on total application resident memory. History and undo remain session-only; final edits still persist normally.

## Verification

Hardware: **8 GB M1 MacBook Air** (`MacBookAir10,1`). Software: macOS 26.6.2, Swift 6.3.3, Command Line Tools.

| Check | Result |
| --- | --- |
| Original regression reproduction | Both disposable-file regressions failed before the fixes: source overwrite and cancellation before scanning. |
| Causal verification | Temporarily disabling just original protection and pre-worker cancellation made the same two tests fail again with five assertions. Restoring the fixes made both pass. Sources were restored automatically. |
| Full test suite and debug build | Passed: 224 executed tests; two opt-in performance tests skipped. The framework reports 226 total cases. All five available real-RAW tests ran and passed. |
| Reliability regression coverage | 18 new tests cover originals/aliases, atomic publication/failure cleanup, cancellation, project replacement, same-ID reopening, copy-worker cleanup, complete import saves, disconnected-save recovery, reference imports, and undo/history limits. |
| Isolated brush benchmarks | Both passed. Initial 40-stroke raster: **368.9 ms**. Exact cache reuse: **0.0117 ms**. Slowest appended point to a 60-stroke mask: **2.73 ms**. |
| Release bundle and strict signature | Passed: optimized release build, local 0.3.4 (9) app bundle, and `codesign --verify --deep --strict`. |
| Deterministic source review / formatting | `./scripts/agent-review.sh all` and `git diff --check` passed. The source reviewer is a source-search tool, not functional acceptance. |

Commands:

```sh
./scripts/test.sh
./scripts/test.sh --filter ReliabilityTests
./scripts/benchmark-masks.sh
./scripts/build-app.sh
codesign --verify --deep --strict PerceptionEditor.app
```

Logs are kept under `.build/`: `reliability-before.log`, `reliability-focused.log`, `reliability-full.log`, `reliability-causal-red.log`, `reliability-causal-green.log`, `reliability-mask-benchmarks.log`, and `reliability-release-build.log`. They are local verification artifacts, not committed project data.

## Remaining validation

The fixes and automated gate are implemented. The full 100–200-distinct-photo workflow and combined process-memory profile remain a separate acceptance pass: the local sample directory contains 16 RW2 files. The 200-photo regression verifies undo cardinality and retention behavior using synthetic project references; it does not substitute for a complete real shoot. Current save-error layout and import-stop interaction still need hands-on UI acceptance, and the minimum macOS 15/Swift 6.1 environment has not been rerun here.

The next implementation item is batch export. This pass establishes the original-file protection and complete-output publication boundary that its queue should reuse.
