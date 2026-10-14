# Project review — October 7, 2026

Overall assessment: **B− as a development project; C as a production-ready replacement for Lightroom.** These are qualitative assessments of capability and evidence, not percentages of roadmap completion. The project has substantial native photo-editing functionality and meaningful regression coverage. Its largest immediate problem is that the most advanced features and the strongest reliability work exist in different local versions.

## Scope and revision identity

This review inspected the current external-SSD checkout, the other registered local worktree, live GitHub repository/PR/CI information, relevant production code, tests, roadmap, and historical QA reports. It preserved existing source changes and original media. Historical reports are evidence at their stated revisions, not current release certification.

| Version | Identity | What it contains |
| --- | --- | --- |
| Current checkout | `codex/photo-wheel-zoom`, HEAD `0087443`, 21 modified tracked files and 30 untracked entries before review | Reliability fixes, bounded caches and undo, save recovery, Auto Tone, batch JPEG export; project schema 6 |
| GitHub main | `0350a4c` | Merged foundation, library/culling, RAW develop, masks, wheel zoom, healing/clone; project schema 7 |
| Other local worktree | `codex/auto-basic-edit`, HEAD `5e574f9`, clean | Healing/clone, RAW white-balance eyedropper, subject selection/refinement, sky selection, Auto tone/WB, project file-type declaration; project schema 10 |

The other worktree is `/Users/perceptionmedia/.codex/worktrees/spot-healing-clone/Perception Edit`. GitHub main is four commits ahead of the current checkout's committed HEAD. The advanced local branch has eight commits beyond the locally recorded `origin/main`, whose schema agrees with live main. GitHub showed six merged PRs, no open PRs, and no issues. Its last push was September 27, 2026. None of these facts establishes one combined, tested release.

## Grades

| Area | Grade | Assessment |
| --- | --- | --- |
| Photo feature coverage | B+ | RAW develop, curves/HSL, presets, geometry, masks, healing, and local selection/Auto tools cover much of the intended edit loop. Advanced tools are not all on GitHub or in the current checkout. |
| Architecture | B− | Native SwiftUI, actor-based render services, metadata edits, and a shared color pipeline are sound choices. `EditorStore` remains large; responsibility extraction is partial. |
| Reliability and original protection | C+ overall | The current checkout has strong targeted safety work and passing regressions. GitHub and the advanced worktree still contain the older export/import/cache/undo paths. |
| Automated verification | B | Both meaningful image tests and boundary tests exist, and GitHub main has a green test/build run. Skips, opt-in native model tests, and absent combined-version CI limit coverage. |
| Target-hardware performance | C | Isolated M1 RAW profiling is useful and explicitly qualified. A full displayed 100–200-photo job, including new segmentation/healing tools, has not been established. |
| Delivery and release integration | C− | Batch delivery is implemented locally but uncommitted and absent from the advanced worktree. No single release candidate combines the progress. |

## Findings, in priority order

### P1 — Integrate original-media protection into the advanced/GitHub version

The advanced worktree's `PhotoRenderer.swift:305–332` renders directly to the requested destination. `EditorStore.swift:767–806` does not validate that destination against project originals. Exporting a JPEG/PNG onto a referenced original of that type is not prohibited by the application, and publication does not use a temporary completed output. This is a source-confirmed safety gap; this review did not overwrite a fixture to reproduce it.

The current checkout already has `ExportFileSafety`, path/symlink/hard-link checks, atomic publication, protected-original tests, and collision-safe batch publication. Integrate that boundary into every export caller in the feature branch before treating it as a dependable deliverable. The corresponding older export implementation is also present in GitHub's merged healing baseline.

### P1 — Import callbacks in the advanced version are not bound to project identity

In the advanced worktree's `EditorStore+Ingest.swift:150–183`, scanning and copy callbacks later call `self.addIngestedFile` and update ingest state without an operation/project-generation check. Switching projects while scanning/copying can let an old operation update the new project's state. The current checkout implements operation/generation guards, cancellation, draining, and reconciliation before final save. Port those together rather than only adding a cancellation button.

### P1 — The advanced version omits the memory safeguards needed by the target Mac

Its `CullPreviewCache.swift:32–69` starts detached decodes without an in-flight limit and permits a completion to refill a cleared cache. `ThumbnailCache` keeps an unbounded image dictionary. `EditorStore.swift:350–375` appends whole adjustment-map undo snapshots without the current checkout's shared budget. Adding subject/sky raster masks makes retaining edit history a particularly important workload to profile, although this review did not measure its footprint.

The current checkout has bounded decode work, thumbnail LRU accounting, memory-pressure cleanup, renderer allocation targets/lifecycle cleanup, and bounded undo/history. Those improvements must be retained when integrating schemas 7–10 and the feature work.

### P1 — No revision has demonstrated the complete photographer workflow

The written acceptance remains open for 100–200 distinct Lumix S5 RW2 files on the 8 GB M1. Two-photo batch UI evidence and a 16-file isolated renderer diagnostic do not establish whole-app throughput, footprint, edit responsiveness, or recovery. The segmentation branch also documents unfinished subject/sky quality coverage. Treat delivery and quality/performance milestones as active.

### P2 — Branch and schema drift make status reports misleading across versions

The current checkout writes schema 6, GitHub main schema 7, and the advanced worktree schema 10. Older builds reject newer projects; they cannot be freely substituted during verification. The current `CURRENT_STATUS.md` correctly describes its worktree but omits features elsewhere. The advanced branch lacks the current reliability/status/testing documents and still describes batch delivery as future work. Reconcile documentation around the eventual integrated candidate and test old-schema loading plus new-schema round trips.

### P2 — Expand batch queue acceptance beyond its current automated cases

The current six batch tests cover recipe validation, naming, late collisions, resizing, selection order, and cancellation before the queue starts. The active plan also requires mid-render cancellation, continuing after a failed file, and preventing stale completion after a project switch. Add deterministic automated coverage for these queue-level scenarios during integration; retain the historical two-file Stop check as narrower UI evidence.

## Verification from this review

| Gate | Result | Evidence and limits |
| --- | --- | --- |
| Current checkout diff/source/build | PASS | `./scripts/qa.sh`; diff hygiene, deterministic source reviewer, debug executable build. Source reviewer reports patterns, not functional correctness. |
| Current checkout unit/integration | PASS | Framework reported 247 tests in 43 suites; 244 executed and three opt-in diagnostics skipped; serial run 51.071 seconds. Real-RAW Auto and five RAW development tests executed. |
| Advanced local worktree unit/build | PASS | Fresh serial `swift test --no-parallel` with `--package-path` set to the other worktree, external-SSD scratch path `.build/review-advanced`, and CLT Swift Testing framework/rpath flags. Debug app and tests compiled. Framework reported 247 tests in 42 suites: 243 executed, four optional real-photo/model tests skipped; 56.824 seconds. `git diff --check` and `./scripts/agent-review.sh release` also passed. |
| GitHub main unit/build | PASS at `0350a4c` | Live [Test run](https://github.com/chydes35/perception-media-editor/actions/runs/36313988542) reports 214 cases: 209 executed, five real-RAW tests skipped; executable build passed on macOS 15 with Swift 6.1.2. It does not cover local-only changes. |
| Combined revision CI/compatibility | NOT VERIFIED | No integrated candidate exists. Local Swift is 6.3.3 on macOS 26.6.2; the GitHub baseline passed its macOS 15/Swift 6.1.2 floor, but the integrated candidate has no such evidence. |
| Current hands-on runtime/accessibility | NOT VERIFIED | No fresh UI walkthrough performed. Historical build-15 and two-photo batch checks inspected as historical evidence. |
| Representative media quality | NOT VERIFIED for full acceptance | Existing RAW tests passed, but no fresh broad visual review across lighting, fine edges, masks/healing, and preview/export output. |
| Whole-app 100–200-photo performance | NOT VERIFIED | No representative full-shoot physical-footprint/latency/throughput measurement in this review. |
| Release packaging/signing | NOT VERIFIED | No release bundle rebuilt or signature checked in this review. Debug build is not release certification. |

QA logs: `/private/tmp/perception-review-qa-20261007.log` and `/private/tmp/perception-review-advanced-20261007.log`. Initial sandbox attempts could not access Swift build output maps; the current QA passed after rerunning with the needed cache access. The advanced build cache is on the external SSD, not the nearly full internal drive.

The advanced run skipped `realPhotoPreviewAndExportCheck`, `actualModelRejectsTheIndoorTwoPersonPhoto`, `actualSkyPhotoProducesAnAlignedPortableMask`, and `twoPeopleStaySeparateAndMasksAlignWithThePhoto` because their opt-in environment variables were not configured. Native segmentation quality is therefore not a fresh pass from this run. The other worktree remained clean after testing.

## Recommended next work

**Next milestone: one integrated, dependable photo workflow through batch delivery.**

1. Preserve the current dirty work as reviewable commits, then reconcile it with GitHub main and the advanced local worktree under an ExecPlan. Resolve the two Auto implementations deliberately, preserve schema-10 subject/sky/retouch data, and retain the `.pmedit` file-type packaging fix. Keep caches/build outputs on the external SSD.
2. Bring original protection, import ownership, save recovery, bounded undo/cache work, and the batch queue into that candidate. Run safety regressions against the integrated schema and add the missing queue boundary cases. Update the roadmap/status/architecture/testing documents and submit the candidate for CI.
3. Run a disposable 100–200-distinct-RW2 shoot on the target Mac through verified import, culling, Develop, masks/healing, focus, batch export, save/reopen, and cache release. Record physical footprint including graphics/compressed memory, swap, cold/warm latency, mask response, export time, output integrity, and recovery from disconnected storage/cancellation. Set workload-specific thresholds before declaring the milestone passed.
4. After that gate, prioritize subject/sky quality fixes using actual shoot failures, undo for culling flags/ratings/labels, RAW+JPEG pairing if used, and reusable delivery recipes. Add color/luminance range masks as the next substantial editing feature when the core job is dependable. Continue deferring video and generative removal under the photo-first direction.

This review changes only this report. Existing source edits were preserved. The immediate performance implication is that combining more tools without retaining the memory work would reintroduce known allocation/retention risks. A single tested candidate and representative job evidence would improve the project's grade more than another isolated feature.
