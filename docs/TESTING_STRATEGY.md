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

## Saved real-RAW workflow reproduction

`RealWorkflowTests` is opt-in. Set `PME_WORKFLOW_PROJECT` to a disposable schema-10 project referencing copied RAW files, including a photo with both masks and a heal stroke. Set `PME_WORKFLOW_OUTPUT_DIR` to a disposable directory outside the referenced sources, then run `./scripts/test.sh --no-parallel --filter RealWorkflowTests` with the app closed. The test separates global/mask/healing/combined edits, compares bounded export against an unrestricted pixel reference, checks healed focus release, and asks native analysis for a portrait candidate. Inputs remain read-only; the test writes JPEG outputs. These local fixtures are not uploaded to CI. See the [target-Mac report](WORKFLOW_VALIDATION_2026-10-07.md) for the causal RAW failure and limitations; the portable PNG test alone does not reproduce that failure.

## Selection quality artifacts

The opt-in `SelectionQualityTests` runner accepts `PME_SELECTION_MANIFEST`, `PME_SELECTION_OUTPUT_DIR` and `PERCEPTION_SKY_MODEL_PATH`. It generates local native masks, overlays and production exports sequentially for inspection. Expected empty results are observations; structural failures fail QA. It does not assign a segmentation-quality pass from a nonempty mask. See [October 8 selection evidence](SELECTION_QUALITY_2026-10-08.md) for manifest format, sampled failures and remaining gates.
