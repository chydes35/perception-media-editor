# Testing strategy and gates

## Automated gate

Run `./scripts/qa.sh` from the repository root. It checks diff hygiene, runs the deterministic developer source reviewer, then runs the Swift Testing suite without test parallelism and builds the executable through `scripts/test.sh`. Use `./scripts/test.sh --filter <name>` for a focused regression before the full gate. The GitHub Actions workflow runs the same QA entry point on macOS 15. The serial full-suite mode avoids the ingest timeouts observed when resource-heavy render and import tests ran together.

| Gate | Evidence | Scope |
| --- | --- | --- |
| Static/build | `git diff --check`, `swift build`, source review | Syntax, compile, and selected source patterns |
| Unit | Swift Testing for models, geometry, color, masks, safety, and services | Deterministic logic and disposable fixtures |
| Integration | Project/save/import/render/timeline tests | Component contracts and failure recovery |
| Runtime/UI | Hands-on app scenarios | Focus, accessibility, responsiveness, save/relink, interrupted jobs |
| Media quality | Representative real RW2 and video fixtures | Color, highlights, masks, export/preview agreement, compatibility |
| Performance | Target M1/8 GB shoot and timed diagnostic | Whole-app footprint and user latency |

The source reviewer reports patterns for human inspection and does not establish functional correctness. Some real-RAW tests depend on local samples and may skip in CI; report the executed/skipped counts. `scripts/benchmark-masks.sh` and `scripts/profile-memory.sh` are separate diagnostics. Do not present them as automatically covered by `qa.sh`.

## Required level by change

Small documentation-only changes need link and diff checks. A logic fix needs a focused reproduction and relevant tests. A substantial feature or milestone needs the automated gate plus the runtime, media, and performance checks named in its ExecPlan. A release needs the built app, signing verification, representative user flows, and outstanding limitation review.

Each completion report labels every applicable gate **PASS**, **FAIL**, or **NOT VERIFIED**, with the command, hardware, fixture, or reason. A skipped test is not a pass. Keep a milestone active if its required acceptance evidence is missing.

## Saved real-RAW workflow reproduction

`PreviewReopenTests` includes deterministic paused-worker checks for same-project reopening, source relinking and reset cancellation. Its opt-in `PME_PREVIEW_REOPEN_PROJECT` points to a disposable schema-10 project referencing copied RAW files with a saved mask. It exports and fully decodes eight JPEGs, compares each reopened edited preview byte-for-byte with the initial preview, checks saved adjustments and verifies the referenced source SHA-256. Optional `PERCEPTION_SKY_MODEL_PATH` runs fresh sky analysis before the cycles. Run `./scripts/test.sh --no-parallel --filter PreviewReopenTests` with the app closed. This establishes rendering/persistence and lifecycle boundaries; a passing run alone cannot close an intermittent UI black-canvas defect. The second opt-in check runs twelve cold-preview replacements with cache cleanup and alternating overlay state; supplying the model path retains one native sky model and reanalyzes at iterations 0/4/8.

For local tracing, set `PME_PREVIEW_DIAGNOSTICS=1` in tests, or set the Boolean `PerceptionPreviewDiagnostics` only in an isolated candidate’s bundle plist before signing. Capture with `/usr/bin/log stream --style compact --level info --predicate 'subsystem == "com.perceptionmedia.editor" AND category == "PhotoPreview"'`. Metadata records renderer availability/dimensions/histogram bins, store start/coalesce/publish/discard/reset and canvas image/mode/overlay changes. It contains no file paths, image pixels or saved-project values. Normal bundles leave this disabled; tracing is diagnostic evidence, not a photographic or performance pass.

`RealWorkflowTests` is opt-in. Set `PME_WORKFLOW_PROJECT` to a disposable schema-10 project referencing copied RAW files, including a photo with both masks and a heal stroke. Set `PME_WORKFLOW_OUTPUT_DIR` to a disposable directory outside the referenced sources, then run `./scripts/test.sh --no-parallel --filter RealWorkflowTests` with the app closed. The test separates global/mask/healing/combined edits, compares bounded export against an unrestricted pixel reference, checks healed focus release, and asks native analysis for a portrait candidate. Inputs remain read-only; the test writes JPEG outputs. These local fixtures are not uploaded to CI. See the [target-Mac report](archive/WORKFLOW_VALIDATION_2026-10-07.md) for the causal RAW failure and limitations; the portable PNG test alone does not reproduce that failure.

## Selection quality artifacts

The opt-in `SelectionQualityTests` runner accepts `PME_SELECTION_MANIFEST`, `PME_SELECTION_OUTPUT_DIR` and `PERCEPTION_SKY_MODEL_PATH`. It generates local native masks, overlays and production exports sequentially for inspection. Expected empty results are observations; structural failures fail QA. It does not assign a segmentation-quality pass from a nonempty mask. See [October 8 selection evidence](archive/SELECTION_QUALITY_2026-10-08.md) for manifest format, sampled failures and remaining gates.

## Small-person recovery and sky crop probes

`GroupRecoveryTests` uses `PME_GROUP_PROBE_INPUT` for the copied, annotated group RAW. It checks picking, independent editable coverage, native child preservation and floor/ceiling controls. `PME_GROUP_QA_PROJECT_OUTPUT` optionally creates a disposable single-photo project for UI QA. `GroupSelectionProbeTests` additionally requires `PME_GROUP_PROBE_OUTPUT` and writes whole-frame/crop semantic masks. `SkyCropProbeTests` uses `PME_SKY_CROP_PROBE_INPUT`, `PME_SKY_CROP_PROBE_OUTPUT` and `PERCEPTION_SKY_MODEL_PATH` for a separate opt-in experiment. Successful artifact generation does not establish photographic quality. See the [group recovery report](archive/GROUP_SELECTION_RECOVERY_2026-10-08.md).

## Branch-gap sky recovery

`SkyBranchRecoveryTests` accepts `PME_SKY_BRANCH_INPUT` (copied annotated RAW), `PME_SKY_NEGATIVE_MANIFEST` (JSON array of three or more no-sky fixture paths), `PERCEPTION_SKY_MODEL_PATH`, and optionally `PME_SKY_BASELINE_MASK` to verify previous pixel coverage. `PME_SKY_QA_PROJECT_OUTPUT` creates a disposable one-photo UI project. `SkyBranchProbeTests` additionally accepts `PME_SKY_BRANCH_OUTPUT` for local semantic/recovery artifacts. See the [branch recovery report](archive/SKY_BRANCH_RECOVERY_2026-10-08.md) for annotations and unverified photographic cases.

## Expanded blue-object sky controls

`SkyQualityControlTests` accepts `PME_SKY_CONTROL_MANIFEST`, `PME_SKY_CONTROL_OUTPUT_DIR` and `PERCEPTION_SKY_MODEL_PATH`. The JSON array specifies fixture names/paths, `expectNoSky`, and annotated `points` (`name`, top-left normalized `x`/`y`, inclusive byte `minimum`/`maximum`). An optional `baselineMaskPath` records independent-run differences; it does not prove same-prediction monotonicity. Passing sampled blue-object/sky points does not close whole-mask or reflection acceptance. See the [expanded real-RAW report](archive/SKY_QUALITY_CONTROLS_2026-10-08.md).

## Bright-foreground sky exclusion

`SkyForegroundExclusionTests` adds portable person-instance qualification, uncertain-edge preservation, auxiliary-failure fallback and cancellation boundaries. Its opt-in RAW check uses `PME_SKY_FOREGROUND_INPUT` plus `PERCEPTION_SKY_MODEL_PATH` for the copied white-bow portrait; `PME_SKY_FOREGROUND_OUTPUT` optionally writes the corrected PNG and a metadata-correct disposable UI project. `SkyForegroundProbeTests` uses that input/output pair to compare native segmentation methods; generated artifacts are diagnostic evidence, not automatic photographic acceptance. See the [October 9 correction](archive/SKY_FOREGROUND_RECOVERY_2026-10-09.md).

## Workspace picker publication

`WorkspaceTransitionTests` verifies no synchronous observable publication from the picker request, newest-request coalescing, direct-navigation priority and project replacement cancellation. Temporarily restoring immediate publication must fail the focused checks. Native `com.apple.runtime-issues` SwiftUI fault logs supplement target-Mac preview tracing; disappearance of those faults does not alone establish correction of an intermittent black canvas.

## Real video gates

`RealVideoProxyTests` is opt-in. Set `PME_VIDEO_SAMPLE` to a long S5 clip (for example `P1107157.MOV`) for the throughput and frame-count gate. Set `PME_VLOG_SHORT` to a short full-range V-Log clip (`P1107158.MOV`) to check that its proxy keeps the original's levels within 4/1023 per cell mean. Both read the originals only and assert the source file is unchanged. Run them with `--no-parallel`; use `-c release` for throughput numbers. See [the 10-bit video plan](../plans/active/video-10bit-color-pipeline.md) for the gates still to come.
