# Preview ownership after reopening — October 9, 2026

Started from clean `15d85d5` on the photo integration branch. This work investigates the previous release UI observation: an edited canvas stayed black after Export → New → Open → Photo → Sky 1 until overlay refresh.

## Findings and change

The persistent black canvas did not reproduce in this task's baseline attempts. Cold opening, export/reopen with a saved sky mask, and a second release sequence with fresh native sky analysis all displayed the settled image without toggling overlay. Sixteen baseline automated RAW cycles (eight after fresh analysis) produced edited pixels identical to the initial preview. Those passes do not establish that the original UI defect is fixed.

A separate preview lifecycle defect is reproduced deterministically. Reopening the same project preserves its asset IDs, and the old completion checked only the selected ID. A paused pre-reopen render could publish original/edited images into the reopened project while the current render was still pending. Relinking a source under the same asset ID had the same problem. Reset also left the old task running and its busy flag set.

Completion now requires the captured project generation and source URL as well as the selected asset ID and uncanceled task. Reset cancels the old worker and clears its busy flag. The slot remains occupied until its actor call drains; subsequent requests coalesce into one current render, avoiding an accumulating queue during repeated opens. Canceled work skips remaining original/edited actor calls where possible. Synchronous native rendering already underway may finish. An optional injected preview operation lets the regression pause workers at the publication boundary; production uses the existing render actor.

No schema, saved mask, color graph, source-media or context allocation-target changes are introduced. Editing remains 256 MiB, ordinary focus/export 128 MiB, with the existing lazy healing context. These targets do not cap whole-app memory.

## Verification

| Gate | Result and evidence |
| --- | --- |
| Focused lifecycle regression | **PASS** — reopen/relink parameter cases and reset cancellation; temporarily disabling guards/cancellation fails six assertions, restoring them passes |
| Real RAW baseline | **PASS** — sixteen pre-fix export/reopen pixel comparisons, including eight after native sky analysis; this shows the original persistent failure is intermittent/unreproduced |
| Full QA and debug build | **PASS** — `./scripts/qa.sh`: 315 tests in 68 suites, **297 executed / 18 skipped**, 99.929 seconds; source/diff checks and debug executable build pass. The enabled eight-cycle RAW test uses the production-style separate 128 MiB export actor after fresh native sky analysis; JPEGs fully decode at 4000 × 6000, saved adjustments/pixels match and source SHA-256 is unchanged |
| Isolated release build/signature/plist | **PASS** — release build 52.76 seconds; ad-hoc deep strict signature verification and plist lint |
| Corrected release UI/save/export/source integrity | **PASS** — M1/8 GB isolated candidate: save → export → new → reopen → photo → Sky 1 displays edited photo/overlay without a post-reopen toggle; schema 10, media identity and every saved adjustment unchanged; UI JPEG fully decoded to 4000 × 6000 PNG; original and copied RAW match the earlier inventory SHA-256 |
| Original persistent black-canvas cause/correction | **NOT VERIFIED** — current baseline UI and RAW checks already pass without this change |
| Broad performance and milestone acceptance | **NOT VERIFIED** — no matched timing/ceiling pass or genuine single-shoot acceptance; one-worker coalescing and existing cache bounds retained |

Artifacts remain local under `.build/sky-foreground-recovery/focused/` and `.build/preview-reopen-validation/`. Fresh selection autosaved a second sky mask into the disposable `ForegroundQA.pmedit` before Save As created `PreviewReopenFresh.pmedit`. The corrected release flow preserved both saved masks and all other adjustments byte-for-byte against the recorded pre-flow metadata. Logs use `/private/tmp/perception-preview-*.log`. A first analysis diagnostic incorrectly relied on bundle model discovery and reported `.missingModel`; explicitly loading the pinned local model corrected the test harness before the successful baseline run.

Observed corrected release physical footprint: lifetime peak **762,498,304 bytes (727.2 MiB)**, post-export **210.8 MiB**, after project replacement **92.5 MiB**. This run did not perform fresh native analysis inside the corrected app, so its lower peak cannot establish an improvement over the preceding sky-analysis workflow. No accepted ceiling or matched speed pass is claimed.

The [active plan](../plans/active/preview-reopen-recovery.md) stays open until the persistent black-canvas cause is reproduced and causally verified. The next reliability step is that reproduction, followed by remaining Phase 3 fine-edge/shaded-sky and group-quality work. The original failure evidence in the preceding sky report remains valid for its recorded revision.
