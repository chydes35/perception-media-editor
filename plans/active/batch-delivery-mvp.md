# Batch delivery MVP

Status: active  
Roadmap: [Phase 4 delivery](../../docs/ROADMAP.md)  
Owner: lead Codex agent

## User outcome and acceptance

Export the selected photos from a project into a chosen folder with a JPEG recipe. The user chooses quality, optional long edge, and a filename suffix, then sees progress, can cancel between or during files, and receives a per-file result. The queue never modifies source media or existing deliverables.

Acceptance: selected photos export in project order; recipe settings affect files as shown; same-name sources and existing destinations receive unique names; failed files do not stop the rest; cancellation stops further work and leaves no partial file; project switches cannot let late progress overwrite the new project's state.

Out of scope: PNG batch, metadata/IPTC, watermark, output sharpening, persistent recipes, video export, background jobs after app quit.

## Current state and affected contracts

`ExportWorkspace.swift` exposes single-photo and batch export. `EditorStore.exportSelectedPhoto()` uses a save panel; `EditorStore+Export.swift` captures a stable project-order queue and its originating project generation. `PhotoRenderer.export()` renders a full-resolution source and `ExportFileSafety` prevents writes to referenced originals and publishes atomically. `selectedAssetIDs` is a set, so selection is resolved through `project.media` order. The integrated candidate remains on `.pmedit` schema 10; this work changes no persisted representation.

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
| Static/build | `git diff --check`, Swift build, signed app bundle | PASS — local candidate debug build and diff/source checks via `./scripts/qa.sh`; isolated corrected release bundle/model/plist/ad-hoc signature PASS. Distribution signing/notarization NOT VERIFIED. September checks remain historical. |
| Unit/integration | Naming, collision, resize, publication cancellation, original protection, failure continuation, stale completion; full Swift Testing and CI | Focused batch tests PASS — 10 tests in three suites, including six new boundary scenarios. Current candidate QA PASS — 295 reported tests/58 suites, 290 executed, five skipped, 58.792 seconds, with disposable RAW/native fixtures enabled. Candidate CI PASS at `aa259c8` — [macOS 15/Swift 6.1.2 run](https://github.com/chydes35/perception-media-editor/actions/runs/37716339314), 277 executed, 14 skipped, 39.594 seconds, debug build passed. Final-head documentation follow-up is recorded on draft PR #7. |
| Runtime/UI | Select multiple photos, export and cancel, inspect results | Displayed 100-distinct-S5 workflow exercised import, edits, Stop, save/reopen and delivery. Baseline delivery failed on one healed portrait; corrected repeat is recorded in the [workflow report](../../docs/WORKFLOW_VALIDATION_2026-10-07.md). Historical two-RW2 collision checks remain separate. |
| Media quality | Representative RW2 output | Completed output decode/dimensions/sRGB and exact healed RAW reference pixels PASS; broad varied photographic/selection quality NOT VERIFIED. See workflow report. |
| Performance | 100–200-file target-Mac export footprint and throughput | Measured 100 distinct RAWs from 23 folders on M1/8 GB; report records throughput/whole-app footprint. Acceptance NOT VERIFIED — genuine single-shoot and agreed thresholds remain open. |

## Decisions and remaining work

### October 7 — queue boundaries and candidate CI

User authorized the next step after local integration `8a9d736`: deterministic mid-render cancellation, continuation after a failed file, and stale-completion checks across project replacement. Use an optional injected asynchronous file exporter to pause the queue at a real temporary-file publication boundary; the production default remains one sequential `PhotoRenderer`. Tests use disposable JPEG fixtures and the production atomic publisher, without writes to originals. Run focused tests and full serial QA, create a draft PR for the integrated candidate, and verify macOS 15/Swift CI at that PR's final commit. Do not merge remotely or close the full-shoot milestone. Update the candidate status and label current evidence separately from September checks.

Progress: focused boundary tests pass after supplying fixture dimensions to avoid an unrelated asynchronous metadata backfill on reopen. Mid-publication Stop is checked both on the first file and after one completed file; the missing-source scenario uses the real renderer; late success/failure and replacement-queue state are controlled deterministically. The production renderer, cache target, and publication policy remain unchanged. Mutation verification produced 20 failed assertions without the publication cancellation and generation guards; restoration passes full candidate QA (291 reported tests, 284 executed, seven skipped). The user explicitly authorized the push; the candidate is submitted as draft PR #7. Candidate CI passed at `aa259c8` (277 executed, 14 skipped); the final-head result will be recorded on the PR. Keep this plan active for the remaining full-shoot, UI, media-quality, signing, and performance gates. No persisted schema change is planned.

The initial Auto Tone failure was reproduced, fixed, made red again by temporarily reverting the contrast change, and made green after restoring it. The first 247-test parallel run timed out three ingest scenarios under heavy concurrent load; isolated ingest tests passed. Explicitly serializing the full suite passed twice, so `scripts/qa.sh` and CI now use that mode.

The local app exported `P1107136.RW2` and `P1107137.RW2` to disposable 2,048-pixel JPEGs. A repeat export produced `-2` filenames without changing the first outputs' checksums. Stopping a third run during the first RAW render left no new file. Keep this plan active for representative 100–200-photo throughput, whole-app memory, and broader output-quality acceptance.

Candidate CI setup: the first run failed before Swift tests because `rg` was unavailable on the macOS runner. Add an explicit ripgrep dependency installation before QA; validate the corrected workflow on the final PR head. This does not change app behavior.

The next CI run reached Swift compilation and rejected shared static `CIContext` instances in Auto, sky, and subject fixture helpers on the macOS 15 SDK. Make those contexts computed per call to remove shared non-Sendable state without changing app rendering or disabling concurrency checks; rerun local QA and final-head CI.

CI compatibility corrections verified: macOS 15/Swift 6.1.2 QA passes at `aa259c8`, after the failing runs above. Local QA after all fixture changes reports 284 executed and seven skipped. Production renderer and memory limits remain unchanged. This closes the automated queue/CI work, while the plan remains active for its remaining acceptance gates.

### October 7 — target-Mac workflow and healing correction

The 100 SHA-distinct S5 library sample is varied evidence, not a genuine single shoot. The baseline batch exposed a full-resolution healing render allocation above 128 MiB. A lazy bounded 256 MiB context preserves the edit graph and reference pixels; restoring the previous renderer makes the saved RAW healing cases fail again. Alternate context caches release at focus/export/project/pressure boundaries. Failed subject analysis now ends with an error status instead of stale progress. Full QA, native fixture checks, release packaging, corrected displayed retest, source hashes and performance observations are recorded in the [workflow report](../../docs/WORKFLOW_VALIDATION_2026-10-07.md) and [active validation plan](target-mac-workflow-validation.md). Earlier statements that rendering/targets were unchanged apply to the queue-boundary step, before this verified correction. Keep this plan active for genuine single-shoot, broad output/edge quality and agreed performance acceptance.
