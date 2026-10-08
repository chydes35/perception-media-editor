# Integrate the local photo workflow

Status: complete for local integration; photo/delivery milestone acceptance remains open
Roadmap item: [Photo-first phases 2–4](../../docs/ROADMAP.md)
Owner: Codex

## User outcome and acceptance

Produce one reviewable local branch containing GitHub main, the advanced local photo tools, and the existing reliability/memory/batch-delivery work. Preserve the original branches and the second worktree. All existing edit types must survive save/reopen, presets and batch actions must retain photo-specific edits, and every export must protect referenced originals. One Auto control uses the advanced photo-specific tone/WB analyzer with cancellation and stale-result protection.

Acceptance for this integration step: recoverable snapshot commit; GitHub main and advanced branch ancestry included; no unresolved merges or duplicate Auto UI/service; schema-10 compatibility maintained; focused integration regressions and full serial QA pass; docs identify the combined candidate and separate remaining full-shoot acceptance. This is step 1 of the October 7 review, not a claim that the delivery/release milestone is certified. Publishing, installing/replacing the user's app, broad new features, and a 100–200-photo acceptance run are outside this step.

## Current state and affected contracts

External checkout: `codex/photo-wheel-zoom` at `0087443`, with 21 modified tracked files and 31 untracked entries including the review. GitHub main verified at `0350a4c`. Advanced local branch `codex/auto-basic-edit` at `5e574f9` is clean in its separate worktree. They write project schemas 6, 7, and 10 respectively.

Affected contracts: `EditorStore` lifecycle/undo/save/ingest; renderer/cache allocation and original protection; `PhotoAdjustments` retouch and raster masks; Auto tone/WB; preview/export shared color; model packaging; project file type; scripts and documentation. Preserve schema 10 rather than downgrade or invent a new schema without changing persisted representation.

## Implementation steps

1. DONE — created `codex/photo-workflow-integration`, preserved local work in `c0f10e5`, fetched main at `0350a4c`. Original branches and the advanced worktree remain unchanged.
2. DONE — main merged in `958a773`; advanced branch `5e574f9` merged with reliability/cache/export ownership preserved. [Decision record](../../docs/decisions/2026-10-07-photo-integration.md).
3. DONE — retained advanced Auto tone/WB with cancellable task, generation/source/snapshot guards, one UI control and menu shortcut; retained schema 10 and project content type; extended undo accounting and selection cache cleanup. Seven integration regressions pass.
4. DONE — focused and full QA pass; current status, architecture, roadmap, data model, README, and decision record reconciled. Candidate recorded as a local merge commit; no push or installed-app replacement.

## Safety and performance

No writes to original media. Tests use disposable fixtures. Preserve snapshot commit and source branches for recovery. Build/model caches remain on the external SSD. Keep memory-bounded caches, pressure cleanup, sequential export, cancellation/project-generation checks, and actor-isolated expensive work. Extend undo accounting if necessary for persisted raster masks and retouch strokes; do not sacrifice the existing shoot-wide budget when merging.

## Verification

| Gate | Required check | Result and evidence |
| --- | --- | --- |
| Static/build | Merge/diff hygiene, source reviewer, Swift build | PASS — resolved all conflicts; `git diff --check`, `git diff --cached --check`, source review, debug build via `./scripts/qa.sh` |
| Unit/integration | Old/new schemas, edit preservation, Auto, safety/cache/undo, full serial QA | PASS — 280 executed/7 skipped (287 reported), 55 suites, 59.885 s; seven new integration tests green; old undo/tool-switch behavior reproduced nine failed assertions in two causal tests |
| Runtime/UI | Combined candidate walkthrough | NOT VERIFIED — retain as downstream acceptance unless exercised here |
| Media quality | Real-RAW regression tests and raster/retouch preview/export checks | PASS for available RAW and synthetic mask/retouch preview/export regressions; broad visual acceptance and opt-in native segmentation fixtures NOT VERIFIED |
| Performance | Existing bounded-owner regressions | PASS — existing cache/undo correctness tests and raster/retouch budget regression; full 100–200-photo displayed workload remains downstream NOT VERIFIED |
| Packaging | Model resources and declared project type retained | PASS source checks — `plutil -lint Resources/Info.plist`, pinned hash/model bundling/license retained; release bundle/signature NOT VERIFIED and installed bundle not replaced |

## Decisions, discoveries, and remaining work

- October 7: User authorized starting review recommendation 1. Preserve and integrate local progress; do not push/merge remotely or replace installed app as part of this step.
- Baseline QA from the review: external checkout 244 executed/3 skipped; advanced worktree 243 executed/4 skipped; GitHub main 209 executed/5 RAW skipped on Swift 6.1.2/macOS 15. These are separate baselines, not an integrated pass.

- Final QA log: `/private/tmp/perception-integration-full-qa.log`. Causal red/green logs: `/private/tmp/perception-integration-causal-red.log` and `/private/tmp/perception-integration-causal-green.log`. Initial new-test compile hit a Swift Testing mutating-call macro limitation; assigning the result before asserting fixed the test harness.
- Remaining downstream work: queue boundary coverage/CI, fresh combined UI and photographic quality checks, release signing/packaging, and representative full-shoot physical-footprint/latency/throughput acceptance. Native selection inference and three diagnostics were skipped. Keep the batch-delivery and photo phases active.
