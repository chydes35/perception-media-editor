# Milestone: agentic development bootstrap

Status: complete  
Roadmap source: [photo-first roadmap](../../docs/ROADMAP.md)

## Outcome

Future Codex work starts from a short repository map, uses project-specific role and plan contracts, and reports objective QA gates. This milestone changes developer workflow only; it adds no app feature and does not declare photo delivery complete.

## Delivered files

Root `AGENTS.md`; `.agent/` role and plan templates; coding standards, data contract, performance targets, testing strategy, status, and decision-record location in `docs/`; `scripts/qa.sh`.

## Acceptance

- Documentation links resolve and instructions point to real project files.
- `scripts/qa.sh` executes the current automated Swift and source-review gate.
- A completion report distinguishes automated results from unverified real-shoot/UI performance.

## Gate

| Gate | Result | Evidence or next action |
| --- | --- | --- |
| Documentation links and diff | PASS | 24 Markdown files checked; no broken local links; `git diff --check` passed |
| Swift app build | PASS | `./scripts/qa.sh` and signed local app bundle completed |
| Swift tests | PASS | `./scripts/qa.sh` ran 247 tests in 43 suites successfully with controlled concurrency |
| Runtime/UI | NOT APPLICABLE | No app behavior changed |
| Real media/performance | NOT APPLICABLE | No render behavior changed; existing acceptance stays open |

The test originally had a nested `#require` macro that prevented compilation. After separating the macro calls, the focused repro showed contrast offsetting the exposure correction. The Auto Tone change preserves neutral contrast for a large exposure move. The focused test passed, failed when that change was temporarily reverted, then passed again after restoration. The full gate passed with `--no-parallel`; see the active batch-delivery plan for subsequent real-media acceptance work.
