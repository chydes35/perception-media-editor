# Current development status

Updated: 2026-10-07. This maps the local integration candidate, not a certified release. The branch is `codex/photo-workflow-integration`; snapshot commit `c0f10e5` preserves the formerly uncommitted reliability/memory/batch-delivery work. GitHub main at `0350a4c` and the advanced local photo branch at `5e574f9` are integrated. Their original branches and the second worktree remain available. The combined candidate is pushed to [draft PR #7](https://github.com/chydes35/perception-media-editor/pull/7) following explicit user authorization. The installed app was not replaced.

## Product position

The photo-first roadmap is authoritative. Phases 0 and 1 are marked complete with their listed follow-ups. RAW Develop/presets, masks/healing, and delivery remain active until their written acceptance gates pass. Smart culling is later; video development remains deferred.

The candidate includes verified card import, culling, RAW Develop, white-balance sampling, presets/sync/history, gradient/brush/subject/sky masks, healing/clone, advanced Auto tone/WB, single-photo JPEG/PNG export, and sequential batch JPEG delivery. It retains original-file export protection, operation-bound ingest, persistent save recovery, bounded undo/cache ownership, memory-pressure cleanup, and the `.pmedit` content-type declaration. Auto has one control beneath the histogram and the existing menu shortcut; pending results are canceled by navigation, manual edits, and tool changes.

Project schema remains **10**. Schema 6–9 data loads and resaves as 10; tests preserve repairs, raster masks/refinements/corrections, RAW settings, and geometry. Older applications cannot open newly saved schema-10 projects. Bundle metadata identifies candidate build **16**, but the installed app was not replaced.

The in-app workflow agents are described in [AGENTS.md](AGENTS.md). Coding-agent instructions start at the repository root [AGENTS.md](../AGENTS.md).

## Current verification

- **PASS — automated QA:** `./scripts/qa.sh` reports 291 cases in 56 suites: **284 executed, seven skipped**, with a 38.450-second serial test run and successful debug app build. Diff/source checks and staged diff hygiene passed.
- **PASS — integration boundaries:** seven new tests cover schemas 6–10, photo-specific sync boundaries, raster/repair undo cost, async Auto preservation/cancellation, same-project reopen/generation identity, and switching into mask/repair tools. Two causal checks failed under old behavior (nine assertions) and passed after restoration/fix. Existing original protection, import/save recovery, cache/undo, batch, RAW, and synthetic mask/healing preview/export regressions also pass in this combined candidate.
- **PASS — batch queue boundaries:** ten focused tests in three suites include six new scenarios for first/later-file publication cancellation, unreadable-file continuation through the real renderer, late success/failure after reopen/replacement, and an old queue completing while a new queue is active. Removing publication cancellation and generation guards produced 20 failed assertions; restoring them passes full QA. Production rendering and cache limits are unchanged.
- **PASS — packaging source checks:** `plutil -lint Resources/Info.plist`; schema-10 file type and hash-pinned sky model packaging/license scripts retained. This is not a release bundle/signature verification.
- **NOT VERIFIED — opt-in checks:** three performance diagnostics, broad Auto photo preview comparison, native indoor/outdoor sky inference, and the real two-person subject fixture were not configured in this run. A skip is not a pass.
- **NOT VERIFIED — combined candidate acceptance:** fresh hands-on UI/accessibility, broad photographic selection/output quality, release packaging/signing, and the full 100–200-distinct-RW2 displayed workflow/memory/throughput run.

**NOT VERIFIED — candidate CI:** the macOS 15 Test workflow is running on draft PR #7. Local QA is complete; the final-head CI result will be recorded on the PR before handoff.

Current QA log: `/private/tmp/perception-batch-boundaries-full-qa.log`; boundary mutation log: `/private/tmp/perception-batch-boundaries-causal-red.log`. Earlier integration log: `/private/tmp/perception-integration-full-qa.log`. Focused and causal logs use `/private/tmp/perception-integration-*.log`. See the [completed local integration plan](../plans/completed/photo-workflow-integration.md) and [Auto/schema integration decision](decisions/2026-10-07-photo-integration.md).

## Historical evidence and next work

The [October 7 review](PROJECT_REVIEW_2026-10-07.md) describes the versions before integration. September [reliability](RELIABILITY_PASS_2026-09-28.md), [memory optimization](MEMORY_OPTIMIZATION_2026-09-28.md), [memory profile](MEMORY_PROFILE_2026-09-28.md), [batch delivery](BATCH_DELIVERY_2026-09-29.md), and [advanced Auto/installed-app QA](QA_AUTO_ADJUSTMENTS.md) remain evidence for their recorded revisions. Their UI/signing/performance passes do not automatically apply to this candidate.

Next: finish candidate CI, then run the representative photographer workflow with 100–200 distinct RW2 photos on the target Mac, measuring export throughput and whole-app memory while checking results and cancellation. The [batch delivery plan](../plans/active/batch-delivery-mvp.md) stays active for full-shoot and quality/performance acceptance. Persistent delivery recipes, output sharpening, P3, copyright/IPTC, and watermark remain later delivery work. Subject/sky quality still needs fine-detail and varied real-shoot validation.
