# Group selection recovery experiment

Status: active
Roadmap: [Phase 3 selection quality](../../docs/ROADMAP.md)

## Outcome and bounds

Recover visibly missed people in the recorded group RAW without merging existing individually selectable people, changing saved masks/schema, or blindly expanding foreground coverage. Probe Apple's whole-person semantic segmentation and human detection against group, portrait, fur and indoor controls. Integrate a bounded fallback only if annotated foreground/background checks and inspected masks improve. Branch-heavy sky inference remains a separate measured investigation; guided refinement cannot recover labels absent from the model output.

## Implementation and safety

Start clean at `7c6374f`. Use read-only disposable RAW copies and external-SSD diagnostic artifacts. Inference stays on the subject service actor, sequential and capped to existing source dimensions. A fallback must preserve point picking, candidate identity, union consistency, cancellation and portable raster saves. No model download or schema change is planned.

## Verification

Probe baseline/new masks and annotated points first, then focused regressions, prior two-person/native fixtures, full QA, displayed group picking/save/export, source hashes and timing/memory observations. Temporarily revert any integrated correction to prove the group repro becomes red. Record PASS/FAIL/NOT VERIFIED for required gates. Broad quality, sky follow-up and whole-shoot/threshold acceptance stay open.

## Progress

An opt-in diagnostic probes balanced/accurate whole-person segmentation and human rectangles. The initial automatic approval review timed out; the permitted retry started successfully. Local SDK headers verify the APIs; online documentation retrieval was unavailable.

Whole-frame balanced/accurate semantic masks still miss the smaller people. Accurate crops recover them, but coarse native labels initially suppress the fallback despite missing editable coverage. Use actual mask coverage and supplemental picking labels. Up to three confident small-human crops are processed sequentially; neighboring-person inclusion is reflected in area names. This recovers two areas while preserving native PNGs and schema 10.

Annotated RAW picking/coverage/background test passes; disabling recovery produces four failed assertions, restoration passes. Full QA: 294 executed/six skipped of 300 reported, 114.022 seconds. Release UI direct picking/list selection, save/reopen, full-resolution JPEG decode and exact persisted PNG comparison pass. Five original/five copy hashes pass. One-photo physical peak 1.13 GiB, post-replacement 196.5 MiB; latency and memory acceptance remain unverified.

Four overlapping sky crops fail the improvement hypothesis: smaller sky coverage and continued missed gaps. Keep production sky inference unchanged and retain the opt-in probe. See [evidence and gate report](../../docs/GROUP_SELECTION_RECOVERY_2026-10-08.md). This plan stays active for broader group coverage/spill, sky quality and accepted performance/full-shoot gates. Next investigate stronger sky labels with branch annotations and negative controls.
