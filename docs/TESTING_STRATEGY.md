# Testing strategy and gates

## Automated gate

Run `./scripts/qa.sh` from the repository root. It checks diff hygiene, runs the deterministic developer source reviewer, then runs the Swift Testing suite without test parallelism and builds the executable through `scripts/test.sh`. Use `./scripts/test.sh --filter <name>` for a focused regression before the full gate. The GitHub Actions workflow runs the same QA entry point on macOS 15. The serial full-suite mode avoids the ingest timeouts observed when resource-heavy render and import tests ran together.

| Gate | Evidence | Scope |
| --- | --- | --- |
| Static/build | `git diff --check`, `swift build`, source review | Syntax, compile, and selected source patterns |
| Unit | Swift Testing for models, geometry, color, masks, safety, and services | Deterministic logic and disposable fixtures |
| Integration | Project/save/import/render/timeline tests | Component contracts and failure recovery |
| Runtime/UI | Hands-on app scenarios | Focus, accessibility, responsiveness, save/relink, interrupted jobs |
| Media quality | Representative real RW2 and video fixtures | Color, highlights, masks, export/preview agreement, compatibility |
| Performance | Target M1/8 GB shoot and timed diagnostic | Whole-app footprint and user latency |

The source reviewer reports patterns for human inspection and does not establish functional correctness. Some real-RAW tests depend on local samples and may skip in CI; report the executed/skipped counts. `scripts/benchmark-masks.sh` and `scripts/profile-memory.sh` are separate diagnostics. Do not present them as automatically covered by `qa.sh`.

## Required level by change

Small documentation-only changes need link and diff checks. A logic fix needs a focused reproduction and relevant tests. A substantial feature or milestone needs the automated gate plus the runtime, media, and performance checks named in its ExecPlan. A release needs the built app, signing verification, representative user flows, and outstanding limitation review.

Each completion report labels every applicable gate **PASS**, **FAIL**, or **NOT VERIFIED**, with the command, hardware, fixture, or reason. A skipped test is not a pass. Keep a milestone active if its required acceptance evidence is missing.
