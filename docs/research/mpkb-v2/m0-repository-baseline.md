# Milestone 0 repository baseline

Audit date: **2026-10-21** (America/Chicago). Initial preservation snapshot: 16:05:23 UTC. Repository: [chydes35/perception-media-editor](https://github.com/chydes35/perception-media-editor). Scope: owner's MPKB V2 WP-000–WP-004 baseline task; **M0 NOT COMPLETE**.

## Read-only initial audit

Historical anchor: `0d3283aa9063bb081ac39554a66221c5e87db53f`, merged PR #16, 2026-10-19 20:01:29 UTC. Fresh GitHub branch/PR queries and `git ls-remote … refs/heads/main` independently confirmed that live `main` still equals this anchor on October 21. PR #15 (Look Match) is its first parent; PR #16 contains the RAW luminance highlight shoulder. Sources, tests and package manifest were inspected rather than inferred from the blueprint.

The chat's PhotoBrain directory initially contained the external audit kit and was not a Git repository. The existing neighboring checkout was:

| Fact | Initial observation |
| --- | --- |
| Branch | `codex/video-stabilization-poc` |
| HEAD | `ac3ded2195778c4f9d34205e0bfdedd18fea37dc` |
| Drift from main | Three committed changes; stabilization proof-of-concept tooling/docs; no changes to `Sources/`, `Tests/` or `Package.swift` |
| Dirty work | Four tracked modifications in stabilization tooling/report/plan, plus one untracked private `.pmedit` |
| Preservation | Before-state branch/status and tracked-diff fingerprint retained privately; no stash/reset/clean/checkout performed there |
| Other linked worktrees | Click/select polish, CI macOS 26, video proxies, Send to Studio OS; left untouched |

Read-only audit completed before candidate edits. A separate agent independently confirmed the findings. Raw audit evidence stays outside the checkout. Subsequent documentation/tooling work uses an independent `--no-hardlinks` local clone under PhotoBrain, on `codex/mpkb-v2-m0-baseline`, starting clean at the anchor. It has no object alternates or dependency on the source repo's garbage collection. Its origin is the repository above. A fresh fetch reconfirmed main. The native chat worktree tool could not target the neighboring checkout from the non-Git chat root; separate clone preserves its worktree metadata and dirty files.

## Inventory and actual code paths at the pin

`git ls-files` confirms **73 source Swift files and 47 test Swift files**. `Package.swift` specifies Swift tools 6.1, macOS 15 and an executable/test target; no external SwiftPM packages. These are file counts, not executed-test counts. Do not import the blueprint's proposed modules as though they exist.

| Concern | Existing code and contract |
| --- | --- |
| Ingest and source protection | `Sources/PerceptionEditor/IngestService.swift`: copied-media verification and SHA-256; `ExportFileSafety.swift`: canonical path/device/inode protection and atomic sibling publication |
| RAW decode | `PhotoRenderer.swift`, `PhotoSourceLoader.makeRawFilter`: Apple `CIRAWFilter`, EDR amount 2, scaled decode, native WB/NR/detail/sharpness and supported lens correction |
| Working sources | `PhotoRenderer`: 2560 px longest edge, default four sources, `kCVPixelFormatType_64RGBAHalf`, extended-linear-sRGB; one current held RAW filter for WB |
| Preview/cull | 1800 px sRGB RGBA8 preview; histogram derived from preview. Default RAW thumbnails/cull can use embedded camera JPEG; edited RAW thumbnails may decode RAW |
| Color graph | `MediaColorRenderer.swift`: retouch/orientation, exposure, contrast/saturation, highlights/shadows, RAW-only luminance shoulder, curves, warmth/tint, vibrance, HSL, local masks, sharpening/vignette, crop |
| RAW shoulder | `HighlightRolloff.swift`; shared photo call sites select it for RAW decode headroom, excluding video and embedded camera JPEG |
| Focus/export | Full-resolution source for 100% crop and export; sRGB JPEG/PNG (8-bit path); ordinary 128 MiB allocation target, lazy 256 MiB healing context. Allocation targets do not cap total process RAM |
| Persistence | `EditorModels.swift:EditorProject.currentSchemaVersion = 10`; `ProjectDocument.swift` atomic JSON save and future-schema rejection; `EditorStore+Project.swift` recovery/save ownership |
| Batch delivery | `BatchExport.swift`, `EditorStore+Export.swift`: sequential JPEG work, cancellation, protected originals, no overwrite of late collisions |
| Preview lifecycle | `EditorStore.swift`, `PhotoPreviewDiagnostics.swift`, `MetalPhotoCanvas.swift`; deterministic reopen tests establish ownership, not closure of intermittent black canvas |
| Masks/repairs | `LocalMasks.swift`, `Retouch.swift`, subject/sky analyzers and existing bounded raster/native inference paths |
| Timeline | `TimelineCompositionService.swift`, `VideoMediaService.swift`, AVFoundation V1/A1; untouched by M0 |
| Automation | `scripts/qa.sh` → `agent-review.sh all` → `test.sh --no-parallel`; `.github/workflows/test.yml` macOS 15 |

See [ARCHITECTURE](../../ARCHITECTURE.md), [DATA_MODEL](../../DATA_MODEL.md), [TESTING_STRATEGY](../../TESTING_STRATEGY.md), [PERFORMANCE_TARGETS](../../PERFORMANCE_TARGETS.md) and [CURRENT_STATUS](../../CURRENT_STATUS.md) for owned contracts. M0 links them instead of introducing replacement architecture. The Apple RAW route is not demonstrated CFA-domain/demosaic/dual-gain control.

## Documentary reconciliation

At pinned main, CURRENT_STATUS's October 14 / PR #7 header predates merged PR #15/#16 and its own October 19 body. Its 320-test CI snapshot is historical; freshly retrieved anchor CI logs instead report 382 tests, **341 executed / 41 skipped**. This task updates the header and labels the earlier evidence historical. No old hardware result is presented as a rerun.

`plans/active/raw-highlight-rolloff.md` says “Schema stays 12,” contrary to schema-10 code and data contract; this task corrects only that typo. Merged Look Match/Metal/highlight implementations retain active plans because their photographic/UI acceptance remains open. Main initially has nine active plans and two completed plans (agentic bootstrap and photo workflow integration); the new M0 plan stays active. Feature worktrees and local stabilization research are not assumed merged into main.

Explicit unresolved checks remain: black edited canvas (not explained/closed), subjective WB drag feel, final RAW highlight look, selection edge/group/sky quality, genuine 100–200-file single-shoot experience and agreed performance thresholds. Main's historical 100-distinct-photo varied-library run does not satisfy the single-shoot gate.

No root application `LICENSE` exists at this pin. `Resources/ModelNotices/SkyModel/LICENSE.txt` and `NOTICE.txt` cover the pinned external Apple-published model, not the app's license. See [risk/decision register](m0-risks-decisions.md).

## Research registration and provenance

The owner's chat task is the execution authority. Kit documents are research inputs, not additional authority. Original research files are not edited or duplicated into Git.

| Input | Provenance / availability |
| --- | --- |
| `Master_Photography_Knowledge_Base_v2_Research_and_Engineering_Blueprint.md` | NOT VERIFIED: absent from scoped file searches in PhotoBrain and existing repo. V1 preservation, V2 registration and exact blueprint exit wording cannot be certified |
| `M0_Repository_Baseline_Audit.md` | External October 21 GitHub read-only audit; SHA-256 `de8054beb3f5268479b16012a94a089c0db297262c52c6786427749aae8677bc` |
| `M0_Fixture_Manifest_Template.json` | External empty v1 template/examples; SHA-256 `3896908ccba216ac970e883b690b35a90e9d1777acd4dc8c4e7daedf5794ac5a`; local v2 contract adds exact permissions and verified/unknown metadata |
| `m0-target-mac-baseline.sh` | External environment helper, SHA-256 `a35f75720b66e45c4c89b89762a8902a89751a13190b01720c512310fbf7658b`; executed for environment only, not `--fixtures`/`--qa`; copied-media validator supplies explicit permissions/integrity |
| `M0_Codex_Execution_Prompt.md` | External reference only, SHA-256 `1e66a5bb70cc2de4bf09fcb3e6dd21287f207d70580159d93e93afe68ecd94ee`; owner's current task takes precedence |

## Evidence index and M0 exit state

Private evidence directory sits beside the clone, outside Git: `m0-evidence/`. Original-media mapping/populated manifest sit separately in `m0-private/` and are never part of the PR. [Test matrix](m0-test-gates.md) records commands, log identities and actual counts; [target table](m0-target-mac.md) records hardware provenance. Source finding and candidate reviews are independent; rejected findings are in [the decision register](m0-risks-decisions.md).

| WP | Result | Remaining exit work |
| --- | --- | --- |
| WP-000 research preservation/registration | NOT VERIFIED | Named blueprint/V1 absent; register immutable research/provenance with owner |
| WP-001 repository truth | PASS for pinned source/branch audit | Runtime/UI gates remain separate; refresh pin after any main drift |
| WP-002 S5 fixtures | NOT VERIFIED for full contract coverage | Nine hash-verified DC-S5 RW2 copies exist locally; no paired JPEG, firmware/mode or required scene coverage established |
| WP-003 existing harness and fixture validation | NOT VERIFIED for all acceptance | Reused suites and safe validator evidenced; standard local QA/toolchain and fixture-specific quality checks remain explicit in matrix |
| WP-004 target workload | NOT VERIFIED | Target identity established; nine-frame diagnostics cannot replace genuine single 100–200-frame shoot and human acceptance |
