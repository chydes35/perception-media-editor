# Restore edited previews after project reopening

Status: active  
Roadmap item: [Phase 2 reliability](../../docs/ROADMAP.md)  
Owner: Codex

## User outcome and acceptance

Export → New → Open → Photo must restore the saved edited RAW and selected mask without toggling the overlay. Reproduce the October 9 black canvas, identify its cause, prove the correction with a failing-before/passing-after check, and verify save/export and original integrity. Do not close this plan from a synthetic ownership check alone.

## Current state and contracts

The worktree started clean at `15d85d5`. At the starting revision, `EditorStore` coalesced previews without generation-bound completion or reset cancellation. The verified lifecycle correction is now present at `12440f4`. `PhotoRenderer` caches bounded working sources and clears context caches after export/replacement. Schema 10 and the shared color pipeline must remain compatible.

## Progress

- [x] Inspect current code and previous failure evidence.
- [x] Cold-open and Export → New → Open → Photo → Sky 1 on the existing release candidate. Both settled images display correctly this time, without overlay toggles; the previous failure is intermittent.
- [x] Isolate rendering versus store/UI ownership: sixteen baseline RAW export/reopen cycles (eight after fresh native analysis) matched pixels; both old release UI sequences passed on retry.
- [x] Reproduce and correct a separate lifecycle defect: old generations/source URLs could publish previews after reopen/relink. Reset now cancels and drains the single worker; six assertions fail when guards/cancellation are disabled and pass with restoration.
- [ ] Establish whether this lifecycle defect caused the original persistent black canvas. The next traced release run reproduces it with valid renderer/store/view metadata; see the continuation below.
- [x] Full QA: 315 reported, 297 executed / 18 skipped, 99.929 seconds. Isolated release build/signature/plist and target-Mac save/export/new/open/photo/mask pass without overlay refresh.
- [x] Update status and evidence.
- [x] Push `a0a717e` and verify [GitHub CI](https://github.com/chydes35/perception-media-editor/actions/runs/37914664441): 315 reported, 288 executed / 27 skipped, 42.434 seconds, successful debug build. Final documentation-head CI is recorded on draft PR #7.

## Safety and performance

Use the existing copied RAW and disposable project. Never write to original media. Keep decoding off the main actor, bounded caches and coalesced requests. Do not add unbounded retries or increase context targets without measured evidence.

## Verification

| Gate | Required check | Result |
| --- | --- | --- |
| Static/build | `./scripts/qa.sh`, isolated release packaging | PASS — debug/release, signature and plist |
| Unit/integration | Focused lifecycle repro, causal revert, full suite | PASS — six causal failures; restored QA passes |
| Runtime/UI | Target-Mac export/new/open/photo/mask without refresh workaround | PASS for this retry; original persistent failure remains NOT VERIFIED as corrected |
| Media | RAW pixels, saved mask equality, decoded export, source hashes | PASS — eight final RAW cycles, UI saved adjustments, decoded export and original/copy hashes |
| Performance | Observe target-Mac footprint; retain bounded ownership | Observed peak 727.2 MiB and post-replacement 92.5 MiB; matched/accepted thresholds NOT VERIFIED |

## Remaining work

The original black canvas is reproduced in the traced continuation below. It persists with a nonempty renderer histogram and completed publication. Original → Edited restores the existing image without another render. Native image/display invalidation remains to be causally isolated; the lifecycle fix alone does not correct it.

## October 9 continuation

Started with a clean checkout at `12440f4`. Add opt-in local metadata tracing across renderer completion, store publication/discard and SwiftUI canvas updates. Normal builds leave it disabled. Log no source paths, image pixels or saved-project contents. Stress copied masked RAW replacement while a cold preview is pending, alternate overlay state and clear expendable renderer caches. Include a retained native sky model to match the app actor lifetime, rather than discarding the model before reopen cycles. Keep the original failure open until observed and causally explained.

- [x] Focused cold-preview stress and retained-model trace: four checks pass; 84 renderer frames, 30 obsolete completions discarded, three retained-model analyses.
- [x] Run required full QA (298 executed / 18 skipped), isolated traced release/signature/plist and displayed workflow. UI reliability **FAILS** on one persistent black canvas; media/integrity checks pass.
- [x] Record reproduction, source integrity and footprint in [trace evidence](../../docs/PREVIEW_TRACE_2026-10-09.md). Peak 1.096 GiB with fresh native analysis; matched performance acceptance remains NOT VERIFIED.
- [x] Remove the speculative image-view identity change: it and the reverted baseline both pass on retry, so causality is unproven.
- [ ] Push tracing/stress coverage and verify CI.
- [ ] Isolate native image/display invalidation and prove a causal correction; keep this plan active.
