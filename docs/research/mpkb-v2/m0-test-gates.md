# M0 command-to-evidence gate matrix

Date: 2026-10-21. Baseline source pin `0d3283aa9063bb081ac39554a66221c5e87db53f`; isolated branch `codex/mpkb-v2-m0-baseline`. PASS applies only to the stated command/input/revision. [Testing strategy](../../TESTING_STRATEGY.md) remains authoritative. Private logs stay beside the checkout in `m0-evidence/`; no media/private logs are committed. A skip is never a pass. [Sanitized evidence index](m0-evidence-index.json) records private log basenames and SHA-256 fingerprints without media hashes/paths.

## Collected gates

| Command / evidence | CI at pin | Local M1/8 GiB | Counts / limits |
| --- | --- | --- | --- |
| `./scripts/qa.sh`, workflow [39315828017](https://github.com/chydes35/perception-media-editor/actions/runs/39315828017), job 118277050357 | PASS, macOS 15 / Swift 6.1.2, October 19; logs freshly retrieved October 21 | Separate failures below | 382 reported tests: **341 passed / 41 skipped / 0 failed**; 60.846 s test phase. App build PASS. Private RAW/benchmark gates skipped |
| `./scripts/qa.sh` default environment, `qa-baseline.log` | Above | FAIL before tests | **0 executed**; sandbox build-service manifest EPERM, not disk exhaustion |
| Approved unsandboxed same `./scripts/qa.sh`, `qa-unsandboxed.log` | NOT VERIFIED for this environment | FAIL before tests | **0 executed**; default SDK 27 missing `SwiftUIMacros.StateMacro` plugin |
| SDK 26.5 `./scripts/test.sh --build-system native --no-parallel`, `tests-native.log` | NOT VERIFIED (local substitution) | PASS tests + app build | **382 reported: 341 passed / 41 skipped / 0 failed**, 82 suites, 37.744 s. Default QA failure remains recorded; native test flags do not forward to script's subsequent default build, which also passed under SDK 26.5 |
| Candidate full existing suite after orientation test correction, `tests-candidate-full.log` | NOT VERIFIED until candidate CI runs | PASS tests + app build | **382 reported: 357 passed / 25 skipped / 0 failed**, 82 suites, 104.238 s. Approved RAW/WB/reopen opt-ins enabled; memory/portrait/model/specific-highlight opt-ins remain disabled |
| Focused copied-RAW/filter/render/reopen workflow, `tests-real-copies.log` | NOT VERIFIED (private inputs unavailable) | FAIL initial reproduction | **79 reported: 74 passed / 4 skipped / 1 failed**, 17 suites, 103.111 s. `RealRawTests.aFullResolutionViewOfARawFileIsPixelPerfect` width ≥5000 rejects a verified 4000×6000 portrait; existing test assertion corrected to longer edge with independent causal verification tracked below |
| Exact portrait repro, `focus-{baseline,fixed,reverted,reapplied}.log` | NOT VERIFIED (no private RAW in CI) | PASS independent causal verification | Four runs, each **1 executed / 0 skipped**: baseline FAIL → fixed PASS → reverted FAIL → restored PASS; exact test source recompiled each run |
| `MemoryPerformanceTests`, `memory-nine-copies.log` | NOT VERIFIED (opt-in diagnostic) | PASS diagnostic + build | **1 executed / 0 skipped / 0 failed**; nine copied RW2s, 13.082 s. [Target table](m0-target-mac.md) records observations; whole-app performance NOT VERIFIED |
| `python3 scripts/test-m0-fixtures.py` | NOT VERIFIED until candidate CI executes this separate tooling check | PASS | **12 executed / 0 skipped / 0 failed**; synthetic bytes only. Validator initially absent, then green; independent rejection/causal checks recorded locally |
| `python3 scripts/m0-validate-fixtures.py --manifest … --check-template` | NOT VERIFIED until run | PASS structure only | Empty template; dataset still NOT VERIFIED |
| Validator `--manifest "$M0_PRIVATE_MANIFEST" --copies "$M0_COPIES"` | NOT VERIFIED (private) | PASS copy-integrity snapshot | Nine copies matched recorded original hashes before tests. Current-original post-test comparison recorded at closeout; values/paths kept private |
| `git diff --check`, scoped diff/source preservation/link checks | NOT VERIFIED until candidate CI | See closeout below | No application/package/schema change; review new files explicitly because ordinary unstaged diff excludes untracked files |
| Actual app/UI, photographic quality, representative target workload | NOT VERIFIED | NOT VERIFIED | No human visual acceptance or 100–200-file whole-app run. Do not infer from numerical/export/reopen tests |

Counts are directly parsed from individual `✔ Test … passed` completions, excluding only the final `Test run` summary, and `✘`/`➜ Test … skipped` completions. Swift Testing's reported total and parameterized case labels are preserved separately; counts here are completed test declarations, not an invented count of parameter cases. A broad exclusion of names beginning `run` would incorrectly drop the passing `runningLookMatch…` test.

## Reproduce existing acceptance checks

Clear inherited `PME_*` / `PERCEPTION_*` fixture opt-ins first; keep normal system environment. Explicitly set `PME_RAW_SAMPLES` to approved opaque copies or an empty directory. Never rely on its private-folder fallback. Use the installed SDK override only for the documented local fallback; no global SDK configuration changes.

```sh
./scripts/qa.sh

# SDK/native fallback used here; does not relabel failed standard QA as PASS.
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  ./scripts/test.sh --build-system native --no-parallel

PME_WB_RAW="$M0_COPIES/S5-0001.RW2" \
  ./scripts/test.sh --no-parallel --filter HeldRawFilterTests
PME_PREVIEW_REOPEN_PROJECT="$M0_PRIVATE_PROJECT" \
  ./scripts/test.sh --no-parallel --filter PreviewReopenTests
PME_WORKFLOW_PROJECT="$M0_PRIVATE_PROJECT" PME_WORKFLOW_OUTPUT_DIR="$M0_DERIVATIVES" \
  ./scripts/test.sh --no-parallel --filter RealWorkflowTests/savedRawRepairsAndMasksExportTogether
PME_RUN_MEMORY_PROFILE=1 PME_RAW_SAMPLE_DIR="$M0_COPIES" \
  ./scripts/test.sh --no-parallel --filter MemoryPerformanceTests
./scripts/test.sh --no-parallel --filter 'ColorGradingTests|HighlightRolloffTests|PhotoRendererTests'
```

Apply `SDKROOT=…` and `--build-system native` to focused commands on this host as required. Close the app and avoid other heavy work for measurement. The actual combined copied-input run selected:

```text
HeldRawFilterTests|PreviewReopenTests|RealWorkflowTests/savedRawRepairsAndMasksExportTogether|DevelopTests|WhiteBalanceEyedropperTests|HighlightRolloffTests|ColorGradingTests|PhotoRendererTests
```

The separate `RealWorkflowTests/savedRawPortraitHasANativeSubjectCandidate` check remains NOT VERIFIED until an approved representative portrait is enrolled. It was intentionally not selected: a procedural gradient/heal project establishes rendering/persistence prerequisites, not portrait scene coverage. Eight export/reopen cycles and twelve cold-preview replacement cycles passed; procedural repair export generated eight JPEG variants with heal/combined channel differences 0/255. These are not UI or segmentation-quality passes.

## Missing-input skips and prerequisites

| Existing suite / source | Enable condition and current coverage |
| --- | --- |
| `HeldRawFilterTests.swift` | Four tests require `PME_WB_RAW`; skipped in synthetic/CI run, executed on approved copy locally. Timings diagnostic only |
| `PreviewReopenTests.swift` | Two real-project tests require `PME_PREVIEW_REOPEN_PROJECT`; deterministic ownership tests run without it. Both copied-project opt-ins passed |
| `RealWorkflowTests.swift` | Two tests require `PME_WORKFLOW_PROJECT`, output path for repair exports. Repair/export test passed on procedural edits; native portrait-candidate test NOT VERIFIED |
| `MemoryPerformanceTests.swift` | Requires `PME_RUN_MEMORY_PROFILE=1`; folder override `PME_RAW_SAMPLE_DIR`, otherwise private default. Nine-file fresh-process diagnostic passed |
| `TestSupport.RawSample` | Selects first sorted RW2 in `PME_RAW_SAMPLES`, with private directory fallback; ten real-RAW tests across Develop/Auto/WB/Look Match use availability gating. Set directory explicitly |
| `HighlightRolloffTests.swift` | Real sunny-frame assertions need `PME_ROLLOFF_RAW`, band/bleach assertions need `PME_ROLLOFF_DIR` and legacy frame basenames. Four skipped declarations in focused run; synthetic shoulder/color assertions passed. Photographic gate NOT VERIFIED |
| Selection/sky/group/edge probes | Require explicit manifests/inputs, some additionally `PERCEPTION_SKY_MODEL_PATH`; no model downloaded or unknown fixture selected in M0. Quality NOT VERIFIED |
| `MaskPerformanceTests.swift` | `PME_RUN_MASK_BENCHMARKS=1`; separate opt-in diagnostic, not ordinary CI timing assertions |

## Candidate closeout

PASS: candidate full existing suite (357 executed / 25 skipped), app build, independent fixed/reverted/reapplied check, 12 synthetic validator checks, source review, local Markdown links and staged diff hygiene. Post-run copy integrity matches all nine recorded hashes; independent post-test checks confirm **9/9 current originals unchanged**, **9/9 copies matched**, and neighboring checkout HEAD/status/tracked diff unchanged (`independent-original-integrity.json`). The initial failures remain above. The scoped candidate changes documentation, two fixture-tooling scripts and one orientation-only existing test assertion; application code/package/resources/workflow are unchanged. Exact final commit/branch/clean state is reported in the session/PR; this document's measurement pin names the application code used, avoiding a self-referential commit hash.
