# Project consolidation

Status: active
Roadmap item: [Photo-first reliability and acceptance](../../docs/ROADMAP.md)
Owner: Codex

## User outcome and acceptance

One reviewable integration candidate preserves the latest editor work and the M0 audit,
with an explicit disposition for every open PR and side branch. Current documentation
must distinguish this candidate from published `main` and historical measurements.
No original media, installed app, global configuration, or remote default branch changes.
Do not delete branches/worktrees or merge/close remote PRs in this preparation step.

## Current state and affected contracts

Published main is `0d3283a` (schema 10). Candidate starts at `5d80625`, the
Click to Select polish atop `feat/editor-redesign`; it already contains main,
photo process-version work and click-selection implementation. Code sets project
schema 13 and new-photo process version 1. Opening old files is supported; saving
advances the schema, and schema-10 builds cannot reopen candidate saves. Use copies.

Primary checkout is dirty on stabilization research. Its HEAD/status and five
dirty-file hashes are recorded locally for a final preservation comparison.
Candidate worktree is on the external SSD, with build/module caches inside `.build`.

## Implementation steps

- [x] Inspect GitHub PR bases, checks and branch ancestry; preserve primary state.
- [x] Create isolated `codex/project-consolidation` from `5d80625`.
- [ ] Reconcile M0 audit/tooling with the candidate; retain pinned historical evidence.
- [ ] Compare proxy branch's actual changes with the candidate before deciding whether to merge.
- [ ] Record all branch/PR dispositions and migration/rollback constraints.
- [ ] Rewrite current status and data-model summaries against code; retain dated evidence in archive.
- [ ] Run fixture tooling, migration/selection checks and the applicable automated gate.
- [ ] Independently review findings and candidate; verify original dirty checkout unchanged.
- [ ] Commit/publish a draft candidate PR with accurate checks and remaining acceptance.

## Safety and performance

No new rendering features or schema change. Preserve current schema 13 and process 1
default. No remote deletion, automatic merges, app installation or new toolchain.
Studio OS transfer feature and stabilization research remain separately preserved.
Do not copy private media into Git or discover private fixtures implicitly during QA.
No performance improvement is claimed from consolidation.

## Verification

| Gate | Required check | Result and evidence |
| --- | --- | --- |
| Branch coverage | main/redesign/polish ancestry, proxy comparison, M0 audit included | PENDING |
| Static/documentation | diff hygiene, internal links, source summary matches constants | PENDING |
| Unit/integration | migration 11/12/13, project persistence, selection, M0 validator, applicable full suite/build | PENDING |
| Preservation | compare original HEAD/status/five dirty-file hashes | PENDING |
| Runtime/media/performance | no fresh acceptance claimed; existing gates retained | NOT VERIFIED |

## Decisions, discoveries, and remaining work

The native worktree tool cannot resolve this projectless chat's repository, so Git's
worktree fallback created the external checkout. Candidate selection is an engineering
choice for review, not a claim of release readiness or approval to advance `main`.
Standard local QA compatibility is cleanup step 2; if its known failure occurs here,
record it and run the documented SDK/native substitute separately.
