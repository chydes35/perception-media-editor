# Integrate the local photo workflow

Status: active  
Roadmap item: [Photo-first phases 2–4](../../docs/ROADMAP.md)  
Owner: Codex

## User outcome and acceptance

Produce one reviewable local branch containing GitHub main, the advanced local photo tools, and the existing reliability/memory/batch-delivery work. Preserve the original branches and the second worktree. All existing edit types must survive save/reopen, presets and batch actions must retain photo-specific edits, and every export must protect referenced originals. One Auto control uses the advanced photo-specific tone/WB analyzer with cancellation and stale-result protection.

Acceptance for this integration step: recoverable snapshot commit; GitHub main and advanced branch ancestry included; no unresolved merges or duplicate Auto UI/service; schema-10 compatibility maintained; focused integration regressions and full serial QA pass; docs identify the combined candidate and separate remaining full-shoot acceptance. This is step 1 of the October 7 review, not a claim that the delivery/release milestone is certified. Publishing, installing/replacing the user's app, broad new features, and a 100–200-photo acceptance run are outside this step.

## Current state and affected contracts

External checkout: `codex/photo-wheel-zoom` at `0087443`, with 21 modified tracked files and 31 untracked entries including the review. GitHub main verified at `0350a4c`. Advanced local branch `codex/auto-basic-edit` at `5e574f9` is clean in its separate worktree. They write project schemas 6, 7, and 10 respectively.

Affected contracts: `EditorStore` lifecycle/undo/save/ingest; renderer/cache allocation and original protection; `PhotoAdjustments` retouch and raster masks; Auto tone/WB; preview/export shared color; model packaging; project file type; scripts and documentation. Preserve schema 10 rather than downgrade or invent a new schema without changing persisted representation.

## Implementation steps

1. Create `codex/photo-workflow-integration` and commit the existing local work as a recoverable baseline. Fetch GitHub main without modifying either original branch.
2. Merge GitHub main and `codex/auto-basic-edit`; resolve conflicts by retaining advanced edit semantics and current reliability/cache/export ownership. Record resolution decisions.
3. Reconcile Auto, `.pmedit` packaging, photo-specific preset/sync boundaries, undo accounting for raster/retouch data, and old/new schema tests.
4. Run focused compatibility/safety/Auto tests and full serial QA. Correct integration regressions before committing the candidate. Update current status, architecture, roadmap, and this plan with exact evidence.

## Safety and performance

No writes to original media. Tests use disposable fixtures. Preserve snapshot commit and source branches for recovery. Build/model caches remain on the external SSD. Keep memory-bounded caches, pressure cleanup, sequential export, cancellation/project-generation checks, and actor-isolated expensive work. Extend undo accounting if necessary for persisted raster masks and retouch strokes; do not sacrifice the existing shoot-wide budget when merging.

## Verification

| Gate | Required check | Result and evidence |
| --- | --- | --- |
| Static/build | Merge/diff hygiene, source reviewer, Swift build | PENDING |
| Unit/integration | Old/new schemas, edit preservation, Auto, safety/cache/undo, full serial QA | PENDING |
| Runtime/UI | Combined candidate walkthrough | NOT VERIFIED — retain as downstream acceptance unless exercised here |
| Media quality | Real-RAW regression tests and raster/retouch preview/export checks | PENDING automated checks; broad visual acceptance remains open |
| Performance | Existing bounded-owner regressions | PENDING; full 100–200-photo displayed workload remains downstream NOT VERIFIED |
| Packaging | Model resources and declared project type retained | PENDING source/resource checks; installed bundle not replaced |

## Decisions, discoveries, and remaining work

- October 7: User authorized starting review recommendation 1. Preserve and integrate local progress; do not push/merge remotely or replace installed app as part of this step.
- Baseline QA from the review: external checkout 244 executed/3 skipped; advanced worktree 243 executed/4 skipped; GitHub main 209 executed/5 RAW skipped on Swift 6.1.2/macOS 15. These are separate baselines, not an integrated pass.
