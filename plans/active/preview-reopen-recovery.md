# Restore edited previews after project reopening

Status: active  
Roadmap item: [Phase 2 reliability](../../docs/ROADMAP.md)  
Owner: Codex

## User outcome and acceptance

Export → New → Open → Photo must restore the saved edited RAW and selected mask without toggling the overlay. Reproduce the October 9 black canvas, identify its cause, prove the correction with a failing-before/passing-after check, and verify save/export and original integrity. Do not close this plan from a synthetic ownership check alone.

## Current state and contracts

The worktree started clean at `15d85d5`. `EditorStore` coalesces previews but does not bind completions to project generations or cancel preview work on reset. `PhotoRenderer` caches bounded working sources and clears context caches after export/replacement. Schema 10 and the shared color pipeline must remain compatible.

## Progress

- [x] Inspect current code and previous failure evidence.
- [x] Cold-open and Export → New → Open → Photo → Sky 1 on the existing release candidate. Both settled images display correctly this time, without overlay toggles; the previous failure is intermittent.
- [x] Isolate rendering versus store/UI ownership: sixteen baseline RAW export/reopen cycles (eight after fresh native analysis) matched pixels; both old release UI sequences passed on retry.
- [x] Reproduce and correct a separate lifecycle defect: old generations/source URLs could publish previews after reopen/relink. Reset now cancels and drains the single worker; six assertions fail when guards/cancellation are disabled and pass with restoration.
- [ ] Establish whether this lifecycle defect caused the original persistent black canvas. Current baseline runs do not reproduce it.
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

The original black canvas is not reproduced yet. A possible stale completion is an investigation lead, not an established cause.
