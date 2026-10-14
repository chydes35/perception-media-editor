# Deferred workspace picker publication — October 10, 2026

Started clean at `eaae645`. Structured native SwiftUI fault logs from the October 9 captured black-canvas workflow contain 25 publication-during-view-update faults. Symbolicating their app frames against the saved release executable identifies the workspace picker key-path setter, `workspaceDidChange()`, `refreshPreview()` and `startPreviewRender(for:)`. This establishes an unsafe UI publication path; it does not alone prove every black canvas has that cause.

The picker now calls `requestWorkspaceChange(to:)`. One main-actor task applies the latest request after the synchronous view update returns. A request returning to the current workspace cancels pending navigation; direct model/menu assignments stay synchronous and supersede pending picker work. Project replacement cancels pending work and checks project generation. Schema 10, original media, render graphs and cache budgets are unchanged. Cost is one retained pending navigation task and one event-turn delay; no added decode, image copy or retry.

Four focused checks cover deferred publication, rapid requests, direct navigation priority and replacement cancellation. Restoring immediate publication fails five assertions, including four synchronous observable publications where zero are required; reapplying the fix passes. That causal check proves the publication contract, not the intermittent displayed black-frame correction.

| Gate | Result |
| --- | --- |
| Focused causal regression | **PASS** — `./scripts/test.sh --no-parallel --filter WorkspaceTransitionTests`; immediate-publication mutation fails five assertions, restored four tests pass |
| Full QA/build | **PASS** — `./scripts/qa.sh`: 320 reported tests in 69 suites, **302 executed / 18 skipped**, 156.848 seconds; source/diff review and debug build pass, copied RAW/model inputs enabled |
| Picker-only traced release | **PASS / FAIL** — publication-during-update faults eliminated; fresh analysis/export/reopen/saved-mask sequence reproduces persistent black canvas despite a completed nonempty preview; a later baseline retry displays correctly |
| Media/integrity | **PASS** — original/copy RAW inventory hashes and existing foreground fixture unchanged; schema 10, exact saved adjustments/media after reopen; UI JPEG fully decoded at 4000 × 6000 |
| Performance thresholds | **NOT VERIFIED** — observe candidate; genuine full-shoot/agreed thresholds remain open |
| Intermittent black-frame causal correction | **NOT VERIFIED** — keep [recovery plan](../../plans/active/preview-reopen-recovery.md) active pending displayed evidence |

Local fault metadata, disposable `.pmedit` projects and traces stay under `/private/tmp/` and `.build/workspace-transition-validation/`; private RAW data is not uploaded.

Picker-only release observations: 25 historical SwiftUI publication faults → zero across the picker-only and experimental candidates. The first picker-only run (PID 82314) reproduces a persistent black canvas after mask selection with a nonempty histogram and completed publication. The positive fitted-frame experiment (PID 83093) and the reverted picker-only baseline (PID 85625) both display correctly on retry. The layout experiment is removed: those observations do not establish causality.

Structured AppKit fault frames symbolicate to `NSThemeFrame._positionSharingIndicator` and `NSWindowSharingSessionRecipientIndicator`, including selective window sharing state changes. These negative geometry faults belong to the native window-sharing titlebar indicator; they are not evidence of invalid photo canvas geometry. The experiment also leaves those faults present. The observed black canvas still requires isolation of native image/compositor invalidation and its relationship to window capture; neither a capture artifact nor an application drawing defect is established as its cause.

The reverted baseline completes fresh native sky analysis, save, JPEG export, New, Open, Photo and Sky 3 selection without overlay or comparison refresh. Native analysis takes substantially longer in this retry; a local stack sample places its background work in foreground refinement/Core Image. That observation is not a performance pass. Both picker-only UI exports fully decode at 4000 × 6000. Initial picker-only release build/signature/plist pass (53.24 seconds). Peak 905,727,616 bytes (863.8 MiB), post-export 320,327,552 bytes (305.5 MiB), post-New 232,640,192 bytes (221.9 MiB) are observations, not matched acceptance. The original black-canvas recovery plan remains active; Phase 3 quality and full-shoot performance gates remain open.

**PASS — final source release:** `swift build --disable-sandbox --scratch-path .build -c release --product PerceptionEditor` after removing the experiment, 328.16 seconds; disposable candidate deep strict ad-hoc signature verification and plist lint pass.

**PASS — code-head GitHub QA:** [run 38062170590](https://github.com/chydes35/perception-media-editor/actions/runs/38062170590) at `5d19f60`, macOS 15 / Swift 6.1.2: 320 reported, 292 executed / 28 skipped, 38.925 seconds; source checks and debug build pass. CI does not contain private RAW workflow fixtures.
