# MPKB V2 Milestone 0 baseline validation

Status: active
Roadmap item: [Photo-first acceptance](../../docs/ROADMAP.md)
Owner: Codex; independent baseline and tooling reviewers

## User outcome and acceptance

Establish reproducible repository truth, a private copied-S5 fixture contract, existing-test evidence and target-Mac measurement provenance for WP-000–WP-004. This is documentation and safe test instrumentation only. The owner's 2026-10-21 task supplies scope; the full named MPKB blueprint is unavailable. Its exact exit criteria cannot be certified.

Accept only recorded PASS/FAIL/NOT VERIFIED gates. Keep this plan active until registered research, permitted real fixtures, existing QA, representative single-shoot hardware evidence and photographer checks satisfy the exit gates. Do not replace RAW processing, change schema 10, application color/timeline code or dependencies.

## Current state and affected contracts

- Live GitHub main and isolated baseline: `0d3283aa9063bb081ac39554a66221c5e87db53f`; PR #16 merged 2026-10-19.
- Existing dirty stabilization checkout is preserved. Independent local clone under PhotoBrain on external SSD; branch `codex/mpkb-v2-m0-baseline`.
- Retain existing 47 Swift test files and QA scripts. `TestSupport.RawSample` defaults to private local media: synthetic QA must explicitly select an empty directory and clear inherited fixture opt-ins.
- Add `docs/research/mpkb-v2/` audit, evidence matrix, fixture contract/template, target table and risks/tickets; add one read-only Python standard-library fixture validator and focused synthetic contract checks under existing `scripts/` tooling. No new app tests/frameworks.
- Correct the existing RAW focus test's width-only resolution assertion to use the longer edge, after reproducing failure on an approved portrait copy; no renderer change.
- Reconcile `docs/CURRENT_STATUS.md` from fresh evidence; correct schema-12 typo in `plans/active/raw-highlight-rolloff.md` against code/schema contract.

## Implementation steps

- [x] Read-only audit: branch, dirty state, drift, code paths, test inputs and GitHub main/PR #16; independently checked before reporting.
- [x] Preserve source checkout with before-state fingerprint; create independent external-SSD clone. No source workspace changes copied.
- [x] Record initial evidence separately from candidate diff.
- [x] Define local-only manifest with opaque IDs, explicit read/hash/render/export permissions, verified/unknown metadata, capture uncertainty and private hash provenance.
- [x] Prove validator acceptance/rejection using disposable synthetic bytes before integrating tooling; never read originals.
- [x] Run existing QA and focused acceptance commands on macOS, record actual executed/skipped counts and any environment failures.
- [x] Capture target hardware identity; leave real-media/UI workload unverified without approved inputs and human observation.
- [x] Independent review of every audit finding and candidate diff; scope/privacy/diff checks; preserve initial source fingerprint.
- [x] Prepare reviewed documentation/tooling and orientation-only test diff for a draft PR; scoped staged diff and source/media preservation checked. Publication status is in the session/PR. No merge or release.

## Safety and performance

Manifest and copies live outside Git; a committed template is empty and explicitly non-measured. Only opaque copied basenames are allowed. Validator streams SHA-256 from read-only regular files, rejects symlinks/hardlinks, outputs IDs/status only and does not extract EXIF/GPS. Original hashes, firmware, exposure and capture modes must be supplied/verified locally; unknown values stay null. Permissions attest provenance; software cannot prove consent or that a file was copied rather than moved. No production performance change. Keep build caches on external SSD. Existing benchmark commands are diagnostics, never substitute for whole-app experience.

## Verification

| Gate | Required check | Result and evidence |
| --- | --- | --- |
| Static/build | Scoped diff, links, validator contract checks; existing QA/build | PASS scoped diff/links/validator/source review and SDK 26.5 fallback build; standard default-toolchain QA FAIL; see [evidence matrix](../../docs/research/mpkb-v2/m0-test-gates.md) |
| Unit/integration | Existing Swift suites; actual pass/skip counts | PASS candidate full suite: 357 executed / 25 skipped, 0 failed; initial QA environment failures and portrait-test reproduction remain recorded |
| Runtime/UI | Cold/warm cull, WB drag, focus, masks, save/open, failure recovery | NOT VERIFIED — nine-copy procedural project tests available; representative shoot/human UI checks pending |
| Media quality | S5 RAW/JPEG, highlight, mask/export comparison, original hashes | NOT VERIFIED for full quality — nine approved copied RW2 records populated privately and hash-checked; JPEG pairs/scene coverage/human checks missing |
| Performance | M1/8 GB 100–200 distinct single-shoot baseline | NOT VERIFIED — identity alone is insufficient |

## Decisions, discoveries, and remaining work

2026-10-21: `.agent/PLANS.md` defines plans as living contracts, not approval pauses. Proceed within supplied M0 scope. Native worktree creation is unavailable for this chat's non-Git root; separate local clone avoids writing the dirty neighboring repo's Git metadata. The neighboring private project was not inspected. Owner-supplied test originals were read-only hashed and independently copied; no original writes. Private opaque copies/metadata/project stay outside Git. The audit kit is research input, not authority to execute extra work. V1/V2 research files remain immutable; missing blueprint registration is open.

2026-10-21 discovery: a 4000×6000 portrait exposed an existing width-only ≥5000 focus assertion. The test alone now checks the longer edge; independent verification reproduced original failure, fixed pass, reverted failure and reapplied pass (1 executed / 0 skipped each). The initial combined-suite failure is retained. No renderer semantics changed.

Candidate full-suite evidence: 382 reported tests / 82 suites, 357 executed / 25 skipped / 0 failures in 104.238 s, build PASS, SDK 26.5/native test fallback. Nine-copy memory diagnostic: 1 executed / 0 skipped, sampled channel difference 0/255. These results do not close required photographic, UI, single-shoot or missing-blueprint gates.

Independent closeout: 9/9 supplied-original hashes unchanged, 9/9 copies matched; neighboring checkout HEAD/status/tracked diff fingerprint unchanged. Source/publication privacy review found no original identifiers or media staged.
