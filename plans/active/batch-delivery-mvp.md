# Batch delivery MVP

Status: active  
Roadmap: [Phase 4 delivery](../../docs/ROADMAP.md)  
Owner: lead Codex agent

## User outcome and acceptance

Export the selected photos from a project into a chosen folder with a JPEG recipe. The user chooses quality, optional long edge, and a filename suffix, then sees progress, can cancel between or during files, and receives a per-file result. The queue never modifies source media or existing deliverables.

Acceptance: selected photos export in project order; recipe settings affect files as shown; same-name sources and existing destinations receive unique names; failed files do not stop the rest; cancellation stops further work and leaves no partial file; project switches cannot let late progress overwrite the new project's state.

Out of scope: PNG batch, metadata/IPTC, watermark, output sharpening, persistent recipes, video export, background jobs after app quit.

## Current state and affected contracts

`ExportWorkspace.swift` exposes one-photo export. `EditorStore.exportSelectedPhoto()` uses a save panel. `PhotoRenderer.export()` renders a full-resolution source and `ExportFileSafety` prevents writes to referenced originals and publishes atomically. `selectedAssetIDs` is a set; use `project.media` order for a stable queue. No `.pmedit` schema change is required.

## Implementation steps

- Restore the existing Auto Tone automated baseline failure with a causal repro and focused verification.
- Add a validated batch recipe, stable output-name planning, and no-overwrite atomic publication.
- Add sequential batch service and store state with progress, cancellation, and per-file outcomes.
- Add Export workspace controls and result display.
- Add focused correctness/integration tests, run full QA, and update documentation/status.

## Safety and performance

Protect all project original URLs, including symlink/hard-link aliases. Allocate one full-resolution renderer at a time and clear its caches after each file. Do not keep rendered full-size images or all export data in memory. Downscale only; preserve sRGB output. Cancellation checks occur before render, before publication, and between files. A destination created during rendering must remain intact.

## Verification

| Gate | Required check | Result |
| --- | --- | --- |
| Static/build | `git diff --check`, Swift build, signed app bundle | PASS — final QA and `codesign --verify --deep --strict` |
| Unit/integration | Auto Tone repro, naming, collision, resize, cancellation, original protection; full Swift Testing | PASS — 247 tests in 43 suites via `./scripts/qa.sh`; six focused batch tests pass |
| Runtime/UI | Select multiple photos, export and cancel, inspect results | PASS for two real RW2 files — UI showed 2/2 success, numbered repeat outputs, and 0/2 stopped after Stop |
| Media quality | Representative RW2 output | PARTIAL — one JPEG inspected visually; both 2,048 × 1,366 outputs decoded; broader color/preview comparison not verified |
| Performance | 100–200-file target-Mac export footprint and throughput | NOT VERIFIED — only two real RW2 files in the UI pass |

## Decisions and remaining work

The initial Auto Tone failure was reproduced, fixed, made red again by temporarily reverting the contrast change, and made green after restoring it. The first 247-test parallel run timed out three ingest scenarios under heavy concurrent load; isolated ingest tests passed. Explicitly serializing the full suite passed twice, so `scripts/qa.sh` and CI now use that mode.

The local app exported `P1107136.RW2` and `P1107137.RW2` to disposable 2,048-pixel JPEGs. A repeat export produced `-2` filenames without changing the first outputs' checksums. Stopping a third run during the first RAW render left no new file. Keep this plan active for representative 100–200-photo throughput, whole-app memory, and broader output-quality acceptance.
