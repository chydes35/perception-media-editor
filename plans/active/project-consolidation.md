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
- [x] Reconcile M0 audit/tooling with the candidate; retain pinned historical evidence.
- [x] Compare proxy branch's actual changes with the candidate before deciding whether to merge.
- [x] Record all branch/PR dispositions and migration/rollback constraints.
- [x] Rewrite current status and data-model summaries against code; retain dated evidence in archive.
- [x] Run fixture tooling, migration/selection checks and the applicable automated gate.
- [x] Independently review findings and candidate; verify original dirty checkout unchanged.
- [x] Commit local integration candidate (`aa5904f`, merge parents `5d80625` and `593549a`).
- [x] User explicitly authorized publication on 2026-10-22; pushed branch and opened [draft PR #23](https://github.com/chydes35/perception-media-editor/pull/23). Initial automatic-review rejection was resolved by that authorization. No default-branch integration or existing-PR closure occurred.

## Safety and performance

No new rendering features or schema change. Preserve current schema 13 and process 1
default. No remote deletion, automatic merges, app installation or new toolchain.
Studio OS transfer feature and stabilization research remain separately preserved.
Do not copy private media into Git or discover private fixtures implicitly during QA.
No performance improvement is claimed from consolidation.

## Verification

| Gate | Required check | Result and evidence |
| --- | --- | --- |
| Branch coverage | main/redesign/polish ancestry, proxy comparison, M0 audit included | PASS: seven included branch tips are ancestors; proxy-specific initializer workaround preserved separately |
| Static/documentation | diff hygiene, internal links, source summary matches constants | PASS: diff hygiene, 92 changed-document relative links; schema 13/process 1 match code; independent review found no remaining issues |
| Unit/integration | migration 11/12/13, project persistence, selection, M0 validator, applicable full suite/build | PASS substitute: SDK 26.5/native full suite, 784 reported / 149 suites, 719 passed / 65 skipped / 0 failed declarations, 92.709 s; app build PASS (53.17 s). Validator 12/12 PASS; empty template structure PASS only |
| Preservation | compare original HEAD/status/five dirty-file hashes | PASS: independently compared original HEAD/status and all five hashes, including untracked project |
| Runtime/media/performance | no fresh acceptance claimed; existing gates retained | NOT VERIFIED |

## Decisions, discoveries, and remaining work

The native worktree tool cannot resolve this projectless chat's repository, so Git's
worktree fallback created the external checkout. Candidate selection is an engineering
choice for review, not a claim of release readiness or approval to advance `main`.
Standard local QA compatibility is cleanup step 2; if its known failure occurs here,
record it and run the documented SDK/native substitute separately.

## Verification closeout (2026-10-22)

- Standard `./scripts/qa.sh`: **FAIL before tests** in this sandbox; build service
  could not write its manifest (EPERM). Static/source-review stages passed. Log:
  `/private/tmp/perception-consolidation-standard-qa.log`. This is separate from
  the historical SDK macro-plugin failure and remains cleanup step 2 work.
- Substitute: cleared inherited `PME_*` / `PERCEPTION_*`, set an empty
  `PME_RAW_SAMPLES`, external `.build/tmp`, and SDK 26.5; ran
  `./scripts/test.sh --build-system native --jobs 2 --no-parallel` with the
  required build-service permission. Exit **0**, full tests and subsequent app
  build passed. Log: `/private/tmp/perception-consolidation-native-qa.log`.
  Skipped media/model/benchmark checks are not passes. No private fixture was
  opted in; no installed app was replaced. Existing compiler/linker warnings
  remain; this is not a release-build/signing check.
- `python3 scripts/test-m0-fixtures.py`: **PASS**, 12 checks.
- `python3 scripts/m0-validate-fixtures.py --manifest
  docs/research/mpkb-v2/m0-fixture-manifest.template.json --check-template`:
  **PASS structure only**; dataset/photographic acceptance remains NOT VERIFIED.
- Independent reviewer confirmed candidate ancestry, migrations/defaults,
  branch dispositions, unchanged pinned M0 documents, no application/package
  diff from `5d80625`, corrected documentation and source-worktree preservation.
  Rejected findings: proxy PR wholly redundant; M0 evidence promoted to current
  acceptance; consolidation changes rendering/schema defaults. The one stale
  README schema sentence found during review was corrected and rechecked.

Local preparation and authorized publication are complete. [Draft PR #23](https://github.com/chydes35/perception-media-editor/pull/23) remains open for candidate review and any approved default-branch integration. This plan stays active through that review; no branch deletion or existing-PR closure is implied.
