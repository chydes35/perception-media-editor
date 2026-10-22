# Consolidation candidate and branch disposition

Date: 2026-10-22. Status: prepared for review; no default-branch or release change.

## Candidate choice

Use `codex/project-consolidation`, based on `5d80625`, as the review candidate.
It includes `main` at `0d3283a`, redesign at `44b3499`, merged PR #19 photo
quality/process-version work, merged PR #20 click selection and PR #21 polish.
Merge the M0 audit/tooling from `593549a` while retaining the redesign's current
application/schema contracts. This preserves recent product work that a main-only
cleanup would omit. It does not establish that the redesigned app is release-ready.

## Open PRs

| PR | Existing base / head | Disposition |
| --- | --- | --- |
| [#21 selection polish](https://github.com/chydes35/perception-media-editor/pull/21) | redesign / `5d80625` | Included by ancestry. Keep open until candidate review determines the final merge order; no duplicate implementation |
| [#22 M0 baseline](https://github.com/chydes35/perception-media-editor/pull/22) | main / `593549a` | Include audit, validator and orientation-only test correction. Resolve current-status conflict against schema-13 candidate; retain M0 measurement pins and active acceptance |
| [#14 proxies](https://github.com/chydes35/perception-media-editor/pull/14) | main / `8dc84d8` | Preserve separately. Candidate already has proxy generation, full-range conversion, exact timestamps and key version 3. Actual generator difference is a comment; however the branch has a distinct Swift 6.1 `EditorStore` initializer workaround and walkthrough evidence. Do not label the whole PR redundant or merge older UI wholesale. Reconcile that workaround during cleanup step 2 if needed |
| [#18 CI experiment](https://github.com/chydes35/perception-media-editor/pull/18) | redesign / `31c88c0` | Do not include. Experiment's recorded check failed; current redesign/polish passes macOS-15 CI. Retain macOS-15 workflow and existing deployment/toolchain requirements. Proposed closure only after review |

GitHub checks at inspection: #14, #21 and #22 PASS; #18 FAIL. These are branch
checks, not checks of the combined candidate. No PR is closed, retargeted or merged
remotely by this preparation. After candidate approval, reconcile the existing PRs
against the selected merge path before deleting branch references.

## Other branches and checkouts

| Work | Disposition |
| --- | --- |
| `feat/editor-redesign`, `feat/pv2-scene-pipeline`, `feat/click-to-select-masks` | Preserve; candidate contains their verified remote tips. Local redesign branch is older than its remote tip |
| `plan/10bit-vlog-color` | Preserve as historical development line; candidate contains it by ancestry (verify before any retirement) |
| `feat/send-to-studio-os` at `4e458c7` | Preserve independently. Substantial transfer/client/credential/UI feature is outside consolidation; requires separate integration and server acceptance |
| `codex/video-stabilization-poc` at `ac3ded2` plus dirty files | Preserve primary checkout, including untracked `StabTests.pmedit`. Research has no production acceptance; do not merge it into the editor baseline |
| `perception-media-editor-m0` independent clone | Preserve private evidence and copied-fixture context even after M0 documents are integrated |

No checkout/branch is retired now: each contains either review context, distinct
work, private evidence or uncommitted files. Saving a clean candidate does not
justify deleting those. The canonical candidate is the new worktree; published
main and the installed app remain unchanged until explicit integration/release.

## Compatibility and rollback

- Candidate schema is 13; main schema is 10. Opening older projects and saving
  upgrades the document. Earlier apps reject the newer file; keep an untouched
  duplicate rather than trying to downgrade.
- Process version 1 remains the new-photo default. Existing edits without a
  version decode as 1. Candidate consolidation does not turn on process 2.
- Migration checks cover frame timing (11), gain (12), process version (13),
  saved-project round trips and refusal of unsupported future schemas.
- No renderer, package dependencies, original media or global configuration
  changes are part of this consolidation.

## Exit evidence

The living [consolidation plan](../../plans/active/project-consolidation.md) records
fresh command results, independent review and preservation verification. Current
status must describe this candidate; historical main/redesign measurements retain
their pins and cannot be promoted to combined-candidate passes.
