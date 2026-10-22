# M0 risks, decisions and bounded next tasks

Date: 2026-10-21. Decisions concern this baseline only. Existing application design stays in its owned architecture/roadmap documents.

| Risk / unknown | Decision and next evidence | State |
| --- | --- | --- |
| Unrelated local stabilization work could be lost or accidentally published | Preserve dirty checkout; use independent external clone from verified main. Compare initial status/diff fingerprint at closeout | Preservation gate in test matrix |
| RAW-engine/color/schema scope expansion | Keep `CIRAWFilter`, shared color graph, schema 10, timeline and app dependencies byte-identical to pin | Scoped diff gate |
| Private-media disclosure | Opaque copies, private source map/hashes/EXIF, explicit process permissions, no originals written, no populated manifest/project/media/logs in PR | See [fixture contract](m0-fixtures.md) |
| Camera/capture claims beyond evidence | DC-S5 model verified from copied TIFF tags; firmware and capture mode stay unknown. No sensor-domain/demosaic/dual-gain claim | NOT VERIFIED beyond model/exposure tags |
| Orientation-sensitive focus-test assumption | Initial copied-portrait reproduction failed width ≥5000; existing assertion now checks longer edge, independently red/green/reverted/red/reapplied/green. App code unchanged | Bounded test-only correction; initial FAIL retained |
| Nine supplied RW2s are not representative coverage | Keep scenarios unclassified; no matched camera JPEG, firmware/mode proof or 100–200 distinct single-shoot dataset | NOT VERIFIED |
| Standard local QA cannot use default toolchain here | Record exact failures; SDK 26.5/native fallback proves tests/build separately. No toolchain install, global settings or production workaround | Local standard gate FAIL; fallback PASS |
| Application license unresolved | No root LICENSE at pin. Model Apache-2.0 attribution applies to model only. Owner must choose/confirm application license and contributor provenance before distribution | NOT VERIFIED; no invented license file |
| Named full MPKB V2 blueprint/V1 unavailable | Register research inputs and hashes; leave V1 untouched. Do not assert exact WP exit criteria or completion | WP-000 NOT VERIFIED |
| Existing black canvas, WB feel, highlight look, selection quality | Retain open failures and active plans despite merged implementation; require UI/photographer evidence | NOT VERIFIED |
| Diagnostic RAM/latency could be mistaken for acceptance | Existing benchmark only; no wall-clock CI assertions or invented thresholds. Compare matched baseline/candidate and whole-app workload under PERFORMANCE_TARGETS | WP-004 NOT VERIFIED |

## Rejected findings from independent review

- “HeldRawFilterTests automatically discovers private photos” — rejected; its four tests require `PME_WB_RAW`; discovery fallback belongs to `TestSupport.RawSample`.
- “Application schema is 12” — rejected; code/data contract are 10, and the highlight-plan typo is corrected as documentation only.
- “The app is Apache licensed” — rejected; only model license/notice was found.
- “Three local commits alter production renderer code” — rejected; `Sources`, `Tests` and `Package.swift` diff against main is empty.
- “Portrait focus failure proves reduced RAW resolution” — rejected; verified full-resolution oriented dimensions are 4000×6000.
- “Disk exhaustion caused the QA write failure” — rejected; independently measured free space was 37 GiB internal / 210 GiB external.
- “CI/native logs have only 340 executed tests” — rejected after parser correction: a broad `run` exclusion also removed `runningLookMatchProducesSelectedAndFlaggedProposals`; exact summary exclusion confirms 341 passed / 41 skipped.

## Minimal next engineering tickets (proposed, not remotely created)

1. **M0 research and fixture completion:** supply immutable V1/full V2 blueprint and register provenance in this index; classify approved copied S5 fixtures, add verified camera-JPEG pairs, required edge/highlight/mixed-light scenes and genuine 100–200-file shoot. Use `TestSupport.RawSample`, `HeldRawFilterTests`, `PreviewReopenTests`, `RealWorkflowTests`, `MemoryPerformanceTests`; no engine changes. Exit: private validated manifest, permitted inputs, exact source/copy hashes, complete WP mapping.
2. **Local QA toolchain compatibility:** reproduce `scripts/qa.sh` and `scripts/test.sh` macro-plugin failures on installed CLT/SDK, compare pinned-main CI, then scope an explicit SDK/build-system option only if needed. Exit: same QA entry point works with documented supported toolchain, no release app or dependency changes, causal verification. Do not install another toolchain in M0.
3. **Black-canvas evidence:** existing `MetalPhotoCanvas.swift`, `PhotoPreviewDiagnostics.swift`, `EditorStore.swift`, `PreviewReopenTests.swift`; follow active preview-reopen plan with a disposable copied-RAW project. Exit: reproduced trace and bounded cause/fix, deterministic regression plus independent verification and human transition check. Current passing reopen tests alone do not close it.
4. **RAW/selection photographic acceptance:** existing `HighlightRolloff.swift`, `MediaColorRenderer.swift`, `HighlightRolloffTests.swift`, `SelectionQualityTests.swift` and active plans. Run suitable approved capture pairs/annotated scenes, inspect final look with photographer, and record failures without tuning during M0. If legacy filename requirements impede opaque fixtures, make a separate minimal diagnostic-input ticket.
5. **Target single-shoot baseline:** follow `docs/PERFORMANCE_TARGETS.md`, `scripts/profile-memory.sh`, `MemoryPerformanceTests.swift` and target-Mac active plan. Record cold/warm cull, WB drag feel, focus, masks, export, save/reopen, peak/cleanup footprint and recovery on 100–200 distinct photos; agree operation-specific thresholds from matched baseline/candidate. Exit requires actual whole-app and human evidence.
