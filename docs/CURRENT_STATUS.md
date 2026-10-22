# Current status

Updated: 2026-10-22. This document describes the **integration candidate** on
`codex/project-consolidation`, not published `main`. The candidate starts at
`5d80625` (redesign plus Click to Select polish) and incorporates M0 audit/tooling
from `593549a`. Published `main` remains `0d3283a`. See the
[branch and PR disposition](decisions/2026-10-22-project-consolidation.md).

## Project compatibility

Candidate project schema is **13** (`EditorProject.currentSchemaVersion`). Published
main uses schema **10**. Older projects can be opened; saving writes schema 13,
which main cannot reopen. Test with duplicate project files; rollback means opening
the untouched original with the older app, not saving the upgraded file back down.
New photos still default to **process version 1**; process 2 remains opt-in pending
photographer acceptance. Consolidation changes neither constant nor application code.
Candidate build identifier remains 16; signing/notarization is NOT VERIFIED.

## Implemented in this candidate

- Verified card copies, culling, RAW develop, presets/history, masks, heal/clone,
  batch editing, Look Matching and RAW highlight roll-off from main.
- Photo/Video category navigation and step workspaces from the redesign.
- Process-version 2 infrastructure and photo export recipes (JPEG, TIFF, PNG,
  HEIC with output controls); process 1 remains the default.
- Click to Select with optional local SAM model, include/exclude points,
  preview/accept workflow, click markers and memory-pressure handling.
- Video proxy playback, frame-exact timeline, color transforms/scopes,
  10-bit export and audio gain/meters already present in the redesign.
- M0 pinned-main research, copied-fixture validation scripts and the
  orientation-correct full-resolution RAW test assertion. M0 observations
  remain attached to their stated source pin and inputs.

Implementation is not photographic, hardware or release acceptance. The archived
[redesign snapshot](archive/REDESIGN_STATUS_2026-10-21.md) retains detailed dated
measurements; [M0 evidence](research/mpkb-v2/m0-test-gates.md) retains the main-based
baseline. Neither is a fresh pass of this combined candidate.

## Verification

| Gate | Result and scope |
| --- | --- |
| Published-main GitHub QA | PASS at `0d3283a`, [run 39315828017](https://github.com/chydes35/perception-media-editor/actions/runs/39315828017); M0 audit counted 341 executed / 41 skipped |
| Click polish PR #21 QA | PASS at `5d80625`, [run 39597113519](https://github.com/chydes35/perception-media-editor/actions/runs/39597113519); not combined-candidate evidence |
| M0 PR #22 QA | PASS at `593549a`, [run 39634715213](https://github.com/chydes35/perception-media-editor/actions/runs/39634715213); not combined-candidate evidence |
| Combined-candidate checks/build | PASS SDK 26.5/native substitute: 784 reported, 719 passed / 65 skipped / 0 failed; app build PASS. Validator 12/12 PASS. See [consolidation plan](../plans/active/project-consolidation.md) |
| Standard local QA | FAIL before tests on 2026-10-22: sandbox build-service manifest EPERM. Historical M0 also recorded a default-SDK macro failure. Fresh substitute above passed; cleanup step 2 remains open |
| Genuine 100–200-photo whole-app shoot and agreed performance limits | NOT VERIFIED |
| Signing/notarization | NOT VERIFIED |

## Open acceptance and known limitations

1. **Black edited canvas:** resolution remains unverified. Metal tracing did not
   reproduce it in seven historical attempts; that does not establish a fix.
   Follow [preview recovery](../plans/active/preview-reopen-recovery.md).
2. **Photographic quality:** mask edges, group coverage, shaded sky gaps, WB drag
   feel, final highlight appearance, Look Match kept/touched counts and mixed light
   remain open. Process 2 final appearance needs photographer sign-off before
   changing the default. See [photo quality plan](../plans/active/look-match-agent.md)
   and the archived redesign evidence.
3. **Candidate UI:** complete category/step walkthrough, old-project transitions,
   audio/color controls and Click to Select exclude marker need current in-app
   acceptance. Historical 36-photo recipe checks do not establish a full-shoot pass.
4. **Video performance:** historical redesign measurements include failed playback/
   export memory or throughput budgets. Consolidation does not close those gates.
5. **Remaining product work:** RAW+JPEG pairing, ratings undo, range masks, P3/HDR
   photo output and broader reflection/lighting controls remain separate roadmap work.
6. **Architecture:** `EditorStore` remains large; decomposition is deferred until
   the baseline and acceptance evidence are stable.

## Next

The candidate is published as [draft PR #23](https://github.com/chydes35/perception-media-editor/pull/23), with explicit user authorization on 2026-10-22. Review the candidate and its migration/PR disposition before advancing main. Then make local QA repeatable (cleanup step 2), followed by the complete
photo-shoot acceptance run (cleanup step 3). Studio OS transfer and stabilization
remain preserved outside this candidate; no worktrees or remote PRs are removed.
