# Target-Mac workflow validation — October 7, 2026

Status: sampled target-Mac checks pass after correction; milestone acceptance remains active.

## Candidate and workload

Baseline: draft PR #7 at `d2bfa30`. Hardware: Apple M1 MacBook Air, 8 GB, macOS 26.6.2. Chrome, Codex and Claude remained open. All build caches, pinned model files, disposable input copies, imported shoot, projects and delivery artifacts stayed on the external SSD. Existing app bundles were preserved; a separately identified, ad-hoc-signed release candidate isolated preferences.

Read-only SHA-256 inventory found 321 distinct RAW files among 371 paths, including 193 DC-S5 files. The workload uses **100 SHA-256-distinct DC-S5 RW2 files from 23 dated folders**, 3,609,006,592 bytes (3.36 GiB), with 6000×4000 and 5328×4000 metadata dimensions before EXIF orientation. It is a varied library sample, not a genuine single shoot. No repeated copies count as distinct photos. The test input and imported sources are disposable copies; original-media integrity verification is recorded below.

## Initial displayed workflow

- Verified folder import reported **100 copied and verified**, no backup configured. Start at 02:37:35.972 UTC; incomplete at 02:40:51.315 and complete by 02:41:06.340: roughly 195–210 seconds, including UI observation uncertainty.
- Displayed culling navigation, ratings, picks and compare worked. Develop exposure, advanced Auto, Auto undo/redo and 100% RAW focus were exercised on a real portrait. A pan gesture was attempted before leaving focus, but its pixel movement was not separately inspected; pan timing below comes from the isolated diagnostic.
- Drew a gradient and brush mask, created one heal stroke, and saved. Reopen displayed all 100 photos, two picks and one three-star rating; saved schema-10 data retained two masks and one heal. Project replacement displayed an empty library.
- Stop during a real RAW batch left **one completed JPEG of 100**, no partial file, and returned enabled export controls.
- Full 2,048-pixel, 92%-quality batch processed all 100 items: **99 saved, one failed**. Later photos continued after the edited portrait failed. All 99 completed JPEGs decoded, had 2,048-pixel long edges and sRGB metadata (2048×1366, 1366×2048 or 1538×2048); no temporary publication files remained. Start was 02:46:59.811 UTC; latest output timestamp 02:51:03.783, about **244 seconds**. Completed UI summary was observed by 02:51:22.835.
- Initial subject-selection UI returned to enabled controls without adding a mask while the footer retained “Analyzing subjects…”. Native analysis on the exact RAW portrait later found one candidate; the displayed behavior needs retesting. The separate failure branch was proven to retain stale progress on an unreadable source and is corrected.

## Initial whole-app physical footprint

Measured with `footprint -p <candidate PID> --sample 2 --noCategories -f bytes`; auxiliary physical-footprint peak records transients between samples. RSS is not used as a proxy.

| Stage | Physical footprint | Lifetime peak where recorded |
| --- | ---: | ---: |
| Empty launch | 33.9 MiB | 35.9 MiB |
| Import completed | 120.7 MiB | 127.2 MiB |
| Displayed 100% RAW focus | 531.8 MiB | 1,134.6 MiB |
| After leaving focus, during subject analysis | 322.3 MiB | 1,134.6 MiB |
| After batch export | 271.9 MiB | 1,419.4 MiB |
| Empty project after workflow | 256.3 MiB | 1,419.4 MiB |

These are observations for the initial candidate/workload, not process ceilings or accepted performance thresholds. Import/export wall times include storage and UI overhead. No precise cold/warm culling or slider input-to-display latency was measured.

## Corrected displayed run

The rebuilt release candidate passes bundle/model/plist and deep ad-hoc signature verification. The same saved portrait displays healed 100% focus, accepts a pan gesture and creates a native subject mask. The temporary subject mask was undone; decoded saved adjustments match the baseline exactly. Reopen retains 100 photos, two picks and the rating.

Repeated delivery reports **100 saved, zero failed**, with enabled controls and no partial publication files. This run captured **full resolution / 92% JPEG**: automation activated export immediately after changing the size picker, before the view applied that selection. Output inspection caught the mismatch; it is recorded as full-resolution evidence rather than a repeat of the initial recipe. All 100 JPEGs fully decode, match original oriented dimensions (6000×4000, 4000×6000 or 4000×5328) and have sRGB metadata. Start: 03:17:34.017 UTC; latest output: 03:20:50.399, about **196 seconds**; success summary observed at 03:20:56.582. This differently sized run does not establish a speed improvement over the baseline.

A separate displayed export confirmed the 2,048-pixel setting before activation: **one healed portrait saved, zero failed**, 1366×2048. Its JPEG is byte-for-byte identical to the unrestricted combined-edit reference (`cmp` PASS). This checks the correction and recipe; it is not a second 100-photo scaled batch.

| Corrected whole-app observation | Result |
| --- | ---: |
| Workflow lifetime physical-footprint peak | 1,561.6 MiB (1.53 GiB) |
| After full-resolution batch | 297.8 MiB |
| Empty project after replacement | 198.5 MiB |

The corrected and initial peaks include different preceding UI activity/recipes and are not a controlled before/after comparison. The allocation change may increase active healing memory. Focus/export/cache/pressure paths release the alternate context; measured project replacement lowers physical footprint. Fine-detail pan quality and precise UI latency remain unmeasured.

## Defects and causal verification

The exact saved RAW project isolates the export failure to healing: the 128 MiB context reports a render part requiring 134,776,312 bytes for healing alone and 149,532,860 bytes with masks. Global edits and masks pass at 128 MiB; all variants pass with an unrestricted reference. A lazy bounded 256 MiB full-resolution healing context corrects the failed cases without changing the render graph or source resolution. Restoring the prior renderer makes both RAW cases fail again. Corrected healed/combined output has **0/255 maximum decoded channel difference** from the unrestricted reference; healed focus and release pass. See [allocation decision](../decisions/2026-10-07-full-resolution-healing-allocation.md).

The missing-source subject failure-status test fails with “Analyzing subjects…” under the old branch and passes with completed-failure feedback. Reverting that line makes it fail again. Project data remains unchanged on failure. This verifies feedback, not broad native selection quality. The corrected displayed portrait selection succeeds; broader edge-quality acceptance remains open.

The portable 24 MP PNG test checks export dimensions/reference pixels and passes on both renderer versions; it is not the causal RAW repro. Existing opt-in native two-person separation/edge alignment and indoor sky rejection pass on their real fixture. Native analysis of the workflow's RAW portrait finds one candidate. Broad outdoor sky, hair/edge quality and selection behavior remain separate acceptance.

## Separate renderer diagnostic

`./scripts/profile-memory.sh --no-parallel`, fresh Swift Testing process with the app closed: one test PASS, 15.300 seconds, 16 real RW2 files. It retains ten culling images for historical comparability although the app keeps six. Renderer source caches are cold at first use; OS/storage caches were not forcibly cold. This neutral workload does not exercise the new healing context.

| Observation | Result |
| --- | ---: |
| Four cold renderer working sources | 4,890 ms total |
| Warm preview median / maximum | 9.88 / 11.57 ms |
| First focus / pan median / maximum | 1,348 / 7.95 / 9.54 ms |
| Full-size JPEG export | 1,286 ms |
| Four sources + before/after footprint | 687.8 MiB |
| Focus / after focus / after export | 781.8 / 190.4 / 353.2 MiB |
| Diagnostic peak | 1,298.4 MiB |
| Budgeted RAW preview reference difference | 0/255 maximum channel |

## Verification and remaining gates

| Gate | Result |
| --- | --- |
| Automated QA | PASS — `./scripts/qa.sh` with workflow RAW/native fixtures enabled: 295 reported tests/58 suites, 290 executed, five skipped, 58.792 seconds; source/diff checks and debug build passed |
| Causal reproductions | PASS — exact RAW export red/green/reverted-red/restored-green; subject-status red/green/reverted-red/restored-green |
| Release packaging | Corrected release build/model packaging/ad-hoc deep signature/plist PASS. No notarization/distribution signature claim |
| Runtime/UI | PASS — corrected healed focus/subject selection/save-reopen, 100/100 full-size delivery and isolated 2,048-pixel healed recipe; initial delivery FAIL is preserved above |
| Media quality | Completed output decode/dimensions/sRGB and healed reference pixels PASS; broad visual acceptance NOT VERIFIED |
| Original integrity | PASS — all 100 originals, 100 staged copies and 100 imported copies match the pre-run SHA-256 inventory |
| Performance acceptance | NOT VERIFIED — initial/corrected whole-app observations and isolated diagnostic recorded; genuine single-shoot, agreed thresholds and matched baseline comparison remain open |
| GitHub CI for correction | Final-head gate/result recorded on [draft PR #7](https://github.com/chydes35/perception-media-editor/pull/7); local fixture passes do not imply CI fixture coverage |

Artifacts remain under `.build/workflow-validation/`; logs use `/private/tmp/perception-workflow-*.log`. Those paths are disposable local evidence, not bundled originals or GitHub uploads. The [active validation plan](../../plans/active/target-mac-workflow-validation.md) and [batch delivery plan](../../plans/active/batch-delivery-mvp.md) remain active until their written gates pass.
