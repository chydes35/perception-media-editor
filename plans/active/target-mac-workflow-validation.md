# Target-Mac photo workflow validation

Status: active
Roadmap item: [Photo workflow and delivery acceptance](../../docs/ROADMAP.md)
Owner: lead Codex agent

## User outcome and acceptance

Validate draft PR #7's integrated editor on the 8 GB M1 MacBook Air. Exercise import, culling, Develop, local masks, 100% focus, batch export/cancellation, save/reopen, and cache release. Record real outputs, operation latency, whole-app physical footprint and peak, and remaining quality limitations. A 100–200 distinct-photo single-shoot workload remains required for milestone acceptance; a varied library sample is separate evidence.

## Current state and affected contracts

Candidate starts at `d2bfa30`, with local and macOS 15/Swift 6.1.2 CI QA passing. Existing renderer diagnostics cover 16 real RW2 files, not a displayed SwiftUI workflow. Installed/root app bundles are older and must be preserved. Schema 10 and source media remain unchanged. This task initially changed verification evidence and disposable artifacts; the displayed run exposed the healing allocation and failed-analysis feedback defects, corrected in `PhotoRenderer.swift` and `EditorStore+Subjects.swift` with focused regressions.

## Implementation steps

1. Inventory RAW sources by read-only SHA-256, identify available distinct workload, and record hardware/OS without hardware identifiers.
2. Build an isolated candidate release bundle under the external-SSD `.build/workflow-validation` directory, prepare the pinned sky model, and verify signing/resources.
3. Launch the candidate and exercise displayed workflows with a disposable project and output directory. Measure physical footprint rather than relying on RSS.
4. Run the isolated renderer diagnostic for separate comparable evidence. Check output dimensions, source hashes, saved project round-trip, failure/cancellation, and post-operation release.
5. Record gate results and update current status; preserve open acceptance where representative workload, thresholds, or visual evidence are incomplete.

## Safety and performance

Originals are read-only. Inventory hashes detect duplicate media and will be checked after validation. Outputs, imported copies, project data, and bundles stay in disposable external-SSD directories; preserve existing app bundles. Hashing, decoding, rendering, and export run off the main actor. Record other app activity and avoid interpreting one trial as a whole-app ceiling. Do not add repeated copies to claim distinct-photo acceptance. Set operation-specific measured thresholds before any milestone performance claim; this run establishes candidate observations, not a newly invented pass limit.

## Verification

| Gate | Required check | Result and evidence |
| --- | --- | --- |
| Static/build | Release build, model packaging, signature, diff checks | PASS — corrected release/model/ad-hoc signature/plist and diff checks |
| Unit/integration | Existing final-head QA; isolated real-RAW diagnostic | PASS — current full QA 295 reported/290 executed/five skipped; isolated memory diagnostic PASS |
| Runtime/UI | Displayed import/cull/edit/mask/focus/export/save/reopen | PASS — sampled 100-photo workflow; corrected 100/100 full-size delivery and one 2,048-pixel healed export |
| Media quality | Real RAW outputs, dimensions, preview comparison, original hashes | Output decode/dimensions/sRGB/reference pixels PASS; source hashes recorded in report; broad visual/edge acceptance NOT VERIFIED |
| Performance | Whole-app footprint, latency and 100–200 distinct-photo workload | Measured M1/8 GB workload and diagnostic recorded; acceptance NOT VERIFIED — genuine single-shoot, agreed thresholds and controlled comparison |

## Decisions, discoveries, and remaining work

Hardware confirmed: Apple M1 MacBook Air, 8 GB, macOS 26.6.2. External SSD has about 377 GiB free; all artifacts/build caches remain there. There are 16 RAW paths in `110_PANA`, 49 in Shoots, and 306 in Pictures; hashing is determining actual distinct media. No individual examined dated directory has 100 files. No individual folder has a complete 100-photo shoot. After the optional dataset preference received no answer, validation proceeded with 100 SHA-distinct S5 files from 23 folders. This is separate evidence, not single-shoot milestone acceptance.

The displayed run imported and verified all 100 photos. Culling/ratings/compare, exposure/Auto undo/redo, focus, gradient/brush masks, healing, and save were exercised. Stop left one completed JPEG and no partial file. Full batch delivery exposed Core Image error 3 on the photo with two masks and one heal; later files continue. Add an opt-in saved-project reproduction separating global edits, masks, healing, and combined edits under the production 128 MB allocation target and an unrestricted reference. Investigate and repair verified rendering defects before claiming delivery acceptance. A subject-selection attempt also returned enabled controls without a mask while leaving “Analyzing subjects…” in the footer; that outcome needs separate diagnosis.

Diagnosis: healing alone requires 134,776,312 bytes and combined masks/healing 149,532,860 bytes for a Core Image render part; 128 MiB is insufficient. A lazy 256 MiB context for active full-resolution healing passes the exact RAW reproduction, including identical reference pixels and a healed focus render. Prior renderer restoration makes both RAW cases fail again. Normal targets remain unchanged; alternate caches are released at lifecycle boundaries. The portable PNG reference-pixel test passes on both versions and does not stand in for the RAW causal reproduction. See [allocation decision](../../docs/decisions/2026-10-07-full-resolution-healing-allocation.md).

The missing-photo subject-status test fails on the previous failure handler and passes after adding completed-failure feedback. Native model quality remains a separate acceptance gate. Focused fixes: 11 tests in four suites pass, including opt-in real RAW, pixel equivalence, focus release, retouch and failed-analysis status.

Corrected verification: full `./scripts/qa.sh` with disposable RAW and native fixtures PASS (295 reported, 290 executed, five skipped, 58 suites, 58.792 s). Release build/model/ad-hoc signature/plist PASS. Separate neutral renderer diagnostic PASS (15.300 s), with timings and physical footprint recorded in the [workflow report](../../docs/WORKFLOW_VALIDATION_2026-10-07.md). Corrected displayed portrait focus and native subject mask creation PASS; temporary subject mask was undone and decoded saved adjustments match the baseline before repeated batch delivery.

Corrected delivery reports 100 saved/zero failed. Output inspection identified full-resolution recipe capture during a rapid automated picker/export sequence; all 100 decode at source-oriented dimensions in sRGB. Separately confirming the 2,048-pixel recipe before export produces a healed JPEG byte-identical to the unrestricted reference. Corrected full-size batch takes about 196 seconds, with 1.53 GiB lifetime peak, 297.8 MiB after export and 198.5 MiB after project replacement. Different activity/recipes preclude a controlled before/after speed or memory claim.

Post-run read-only integrity PASS: all 100 original, 100 staged and 100 imported SHA-256 hashes match the pre-run inventory. Broad acceptance remains open; no original media or installed app was replaced.
