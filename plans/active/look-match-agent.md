# Look Match agent — LM1: per-scene smart match

Status: active
Roadmap item: [Phase 2 — RAW develop and presets](../../docs/ROADMAP.md) (adjustment sync) and the Look Matching workflow agent in [docs/AGENTS.md](../../docs/AGENTS.md)
Owner: lead coding agent (Claude Code)
Product plan: "Perception Editor — AI Look-Match Agent Plan" (Claude doc, 2026-10-18). Its phases 1–5 are tracked here as milestones LM1–LM5 so they do not collide with the roadmap's numbered phases.

## User outcome and acceptance

The photographer edits one hero photo per scene in a family-portrait shoot (100–200 Lumix S5 RW2 files). In **Agents → Look Matching**, the app groups the shoot into lighting scenes, finds each scene's edited hero, and proposes adjustments for every other photo in that scene. Each proposal adapts exposure and white balance to that photo's light instead of copying the hero's numbers. Low-confidence proposals are flagged and left unselected. The photographer reviews the list, applies the selected proposals as one undo step, and is told which scenes still need a hero (with a suggested frame).

Acceptance criteria:

1. **Scene grouping** is deterministic. A new scene starts when any of these exceed a threshold between consecutive photos (ordered by capture time): capture-time gap, RAW as-shot temperature (mired), exposure value from ISO/shutter/aperture, or Vision feature-print distance. All thresholds live in one `LookMatchThresholds` value with documented defaults; tune them on a real family-portrait shoot and record the final values in this plan.
2. **Hero detection.** In each scene, the hero is the selected photo if it is in that scene and has non-neutral look groups; otherwise the photo with the most non-neutral look groups (ties: latest capture time). A scene with no edited photo gets **no proposals** and a finding that names a suggested hero (highest median sharpness/exposure-centered frame from the 512 px analysis).
3. **Never overwrite existing work.** A target that already has non-neutral look groups is skipped and listed as "already edited". Crop, rotation, straighten, brush strokes and retouches always stay with their photo (existing `look(keepingGeometryOf:)` contract).
4. **Per-photo solve.** Start from `hero.look(keepingGeometryOf: target)`. Then:
   - **White balance (RAW):** apply the hero's offset from its own as-shot value to the target's as-shot value, in mired for temperature and additively for tint. If the hero kept as-shot WB, the target keeps as-shot WB. **Non-RAW:** reuse the Auto neutral-reference fit.
   - **Exposure:** render hero and target at 512 px through `MediaColorRenderer`; adjust target exposure by log2 of the median-luma ratio, re-render, up to 3 iterations, clamped to ±1.5 EV relative to the hero. Nudge highlights/shadows (bounded ±0.25) only when the target's 98th/2nd luma percentiles still differ from the hero's by more than a tolerance.
5. **Confidence** is a value 0–1 from the final luma/chroma residual and the scene distance. Below `LookMatchThresholds.minimumConfidence` (initial default 0.6) the proposal is flagged and unselected.
6. **Approval.** Proposals carry the computed `PhotoAdjustments`. Apply writes only the selected ones, as one undo step labelled "Look Match"; one undo restores every affected photo.
7. **No persistence change.** Analysis and proposals are never saved in `.pmedit`; project schema stays 10. Agent reports keep decoding when the new fields are absent.
8. **Real-shoot check** (photographer runs it): on a real family-portrait shoot, ≥ 85% of unflagged proposals are kept without touching a slider, and frames in different light (window vs. open shade vs. flash) land in separate scenes or are flagged. Record counts here. If not run, the gate is NOT VERIFIED.

Out of scope for LM1: re-detecting subject/sky masks and skin-tone checks (LM2), a full contact-sheet review grid (LM2), the MCP bridge (LM3), AI review of flagged photos (LM4), learning from corrections (LM5). The existing **Batch Editing** agent keeps its current behavior.

## Current state and affected contracts

Verified at `b4f225d`:

- `AgentEngine.lookMatching` (Sources/PerceptionEditor/AgentEngine.swift) proposes `.copyPhotoAdjustments` for every photo in the hero's folder; `EditorStore.applyLatestAgentChanges()` applies `look(keepingGeometryOf:)` to all of them with one `recordAdjustmentChange`. `AgentEngine.run` is synchronous and reads only metadata.
- `AgentModels.swift`: `AgentChangeKind` has one case; `AgentChange` has no payload; `AgentReport` is `Codable` and round-trips in `AgentEngineTests`.
- `PhotoAdjustments` (EditorModels.swift) with `lookOnly`, `look(keepingGeometryOf:)`; groups in `AdjustmentGroups.swift` (`AdjustmentGroup.looks` excludes white balance).
- `AutoAdjustmentAnalyzer.swift`: 512 px decode via `PhotoSourceLoader.load(_:maxDimension:raw:)`, private `neutralReference`, `colorCast`, `fitWhiteBalance`, `fitTone`; RAW WB via `PhotoSourceLoader.rawInfo(of:)` (`asShotTemperature`, `asShotTint`). Runs in `AutoAdjustmentService` actor. `EditorStore+Auto.swift` shows the request-ID / project-generation / cancellation pattern to copy.
- `PhotoSourceLoader.metadata(of:)` returns width, height and capture date only. ISO, shutter and aperture are not read yet.
- `MediaColorRenderer.render(_:adjustments:includesGeometry:)` and `finishedGeometry(_:_:)` render adjustments onto a decoded `CIImage`.
- `AgentWorkspace.swift` lists agents and shows the latest report with one apply button.

Contracts touched: `AgentChange`/`AgentReport` Codable shape (additive, optional fields), the agent apply path, and the Agents workspace UI. No `.pmedit` change.

## Implementation steps

Record progress under each step as it completes.

1. **Baseline.** Read `AGENTS.md`, `docs/ARCHITECTURE.md`, `docs/DATA_MODEL.md`, `docs/CODING_STANDARDS.md`. Run `./scripts/qa.sh` and record the baseline counts. Work on branch `look-match-lm1`.
   - *Done 2026-10-18 at `b4f225d` on branch `look-match-lm1`.* `./scripts/qa.sh` as written stops in its source-review step on this Mac: `rg` is not installed as a binary (`command not found: rg`), so the script exits 127 before any tests run. QA was therefore run **by substitute** with its two gating steps: `git diff --check` (clean) and `SDKROOT=…/MacOSX26.5.sdk ./scripts/test.sh --no-parallel -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing` (Command Line Tools only, no Xcode). Baseline: **334 tests in 73 suites passed, 308 executed / 26 skipped** (opt-in real-media tests), app build passed, 5 min 37 s. Every later "qa" entry below uses the same substitute.
2. **Shared analysis helpers.** Move `neutralReference`, `colorCast`, `fitWhiteBalance` and the luma-percentile code out of `AutoAdjustmentAnalyzer` into an internal `ImageStatistics` helper both analyzers use. Auto behavior and its tests must not change.
   - *Done `0065b2c`.* `ImageStatistics.swift` also holds the 64 px `pixels` sampler (both helpers need it) and `median`/`clamp`/`rounded`/`linear`. Auto keeps thin private wrappers, so its fitting code is unchanged. `--filter AutoAdjustmentTests`: 11/11 pass, including the real-RW2 test. QA substitute: 334 tests, 308 executed / 26 skipped.
3. **Exposure metadata.** Add an analysis-time reader for ISO, exposure time and f-number (ImageIO EXIF), returning an exposure value. Do not add fields to `MediaAsset`.
   - *Done `a4e24ec`.* `ExposureMetadata.read(_:)` returns ISO, shutter, f-number and the ISO 100 scene EV, `log2(N²/t) − log2(ISO/100)`, so the same light reads the same however the camera was set. Verified on a Lumix S5 RW2 and on EXIF-tagged JPEG fixtures. QA substitute: 338 tests, 312 / 26.
4. **Scene grouping** — new `LookMatchScenes.swift`: `SceneSignal` (asset ID, capture date, as-shot mired, EV, feature print) and a pure `group(_ signals:, thresholds:) -> [[UUID]]`. Feature prints come from `VNGenerateImageFeaturePrintRequest` on the 512 px decode.
   - *Done `c9a2229`.* Also holds `LookMatchThresholds`, hero selection, and (from `a460bdc`) `splitReasons` for tuning. Undated photos sort after dated ones; ties keep project order. A missing signal never splits. Feature prints are normalized to unit length and compared by Euclidean distance (0–2). QA substitute: 344 tests, 318 / 26.
5. **Analyzer** — new `LookMatchAnalyzer.swift` plus `actor LookMatchService`: hero stats once per scene, then the per-target WB and exposure solve and confidence (acceptance 4–5). One 512 px decode alive at a time; check `Task.checkCancellation()` between photos.
   - *Done `6201eb7`.* Two passes. **Survey** (every photo): metadata, EXIF EV, RAW as-shot WB, and a feature print and sharpness score from the 512 px preview `PhotoSourceLoader.loadThumbnail` gives (the camera's embedded JPEG for RAW). **Solve** (each scene with a hero): one hero decode and measurement, then for each target one 512 px decode with the solved RAW WB, up to 3 exposure renders and at most one nudge render. Measurements are sRGB-encoded luma percentiles (2nd/50th/98th) plus median log(R/G) and log(B/G). Non-RAW WB: target warmth/tint = hero's + (target's Auto neutral fit − hero's fit). The highlights/shadows nudge is kept only if it brings the 2nd/98th percentiles closer. Confidence = 1 − (0.35·exposure residual/0.5 EV + 0.15·percentile residual/0.2 + 0.30·chroma residual/0.12 + 0.20·feature distance/(2 × scene threshold)), each term capped at 1. QA substitute: 352 tests, 326 / 26.
6. **Models.** Add `AgentChangeKind.matchLook`. Add optional `proposedAdjustments: PhotoAdjustments?`, `confidence: Double?`, `sceneIndex: Int?`, `isSelected: Bool` (default true) to `AgentChange`, decoded with `decodeIfPresent`.
   - *Done `cff7818`.* `AgentReport.proposedChanges` became `var` so checkboxes can update the in-memory report (Codable shape unchanged). An old-report JSON fixture decodes with nil payload and `isSelected == true`.
7. **Store** — new `EditorStore+LookMatch.swift`: `startLookMatch()` / `cancelLookMatch()` following `EditorStore+Auto.swift` (request ID, project generation, discard stale results, progress in `statusMessage`). Route the Look Matching agent's Run button here. Extend `applyLatestAgentChanges()` to apply only selected `.matchLook` changes, using `proposedAdjustments` but re-checking the target is unchanged since analysis; skip and report any target edited in the meantime.
   - *Done `a4d7d08`.* Progress also goes to `lookMatchProgress` for a progress bar. The analyzed adjustments are kept in memory (`lookMatchBaseline`, never saved) for the "unchanged since analysis" check. Project replacement (New/Open) cancels a running analysis and discards an unapplied Look Match report. `AgentEngine.run(.lookMatching)` now returns only the preflight report (fewer than two photos, or no edited hero). The old copy-everything Look Matching proposal is removed; Batch Editing is unchanged (test `otherAgentsKeepTheirCopyBehavior`). `EditorStore` takes an injectable `lookMatchAnalyzer` for tests, as with Auto. A finished analysis does not switch the Agents view; its report shows under Look Matching. Memory pressure needs no extra hook: between photos the analyzer keeps only numbers and ~3 KB feature prints, and it clears its Core Image caches after every photo.
8. **UI** — `AgentWorkspace.swift`: for Look Matching, show scenes with hero name, a row per proposal (thumbnail, filename, confidence, flagged badge, checkbox), "already edited" and "needs a hero" findings, and Apply Selected / Cancel.
   - *Done `ebd976f`.* While analysis runs, a progress bar and Cancel replace Run Agent. Cancel under the list discards the proposals. "Already edited", "needs a hero" (naming the suggested frame), "could not analyze" and the flagged count appear in Findings. Builds with no warnings. **Not yet seen in the running app.**
9. **Tests** — new `LookMatchTests.swift`, extending `AgentEngineTests` where it fits:
   - grouping splits on each signal independently and is stable for identical input;
   - a fixture darkened by 1 EV solves to exposure ≈ +1.0 (±0.1);
   - RAW WB offset is carried in mired (unit test on the math, plus a RAW fixture when local samples exist);
   - edited targets and geometry/brush/retouch are never overwritten;
   - unselected proposals are not applied; apply is one undo step; undo restores all;
   - stale results after project replacement are discarded; cancellation leaves the project unchanged;
   - old `AgentReport` JSON without the new fields still decodes;
   - originals' bytes are unchanged (existing `TestSupport` fixtures).
   - *Done.* Tests were added with each step; `a460bdc` adds report-builder tests and the opt-in `LookMatchRealShootTests` runner (see Verification). `LookMatchTests` and `AgentEngineTests` total 36 tests (35 run, the runner skips without its env vars). The RAW WB test uses two real RW2 files from `PME_RAW_SAMPLES` (default `/Volumes/ExSSD1/110_PANA`) and skips without them.
10. **Docs.** Update `docs/AGENTS.md`, `docs/CURRENT_STATUS.md`, and add a Phase 2 roadmap line for per-scene look matching. Record tuned thresholds and gate results here.
    - *Done.* Also `docs/ARCHITECTURE.md` (module list). Thresholds below are starting values, not tuned.
11. **Gates.** `./scripts/qa.sh`, then the real-shoot check (acceptance 8) on the 8 GB M1.
    - *Automated gates done 2026-10-18 at `64fae1e` (see Verification).* Real-shoot, runtime/UI and performance gates are open: LM1 stays **active** until the photographer runs the procedure below.

## Safety and performance

- Originals are read only; analysis decodes at 512 px. Apply changes project metadata only, through the existing undo/history path.
- Analysis runs off the main actor in its own actor, never on `PhotoRenderer`'s, so editing previews stay responsive. Respect cancellation, project generation and memory-pressure callbacks; clear Core Image caches after each photo as Auto does.
- Peak memory target: no more than the Auto analyzer's budget plus feature-print buffers for one photo. Measure with `scripts/profile-memory.sh` or Instruments on the target Mac and record it. Do not claim a pass without the measurement.
- Expected time: about 150 decodes at 512 px plus up to 3 renders each; record actual seconds for a 150-photo shoot.

## Verification

| Gate | Required check | Result and evidence |
| --- | --- | --- |
| Static/build | `git diff --check`; Swift build | **PASS** — `git diff --check` clean at every commit; debug build of `PerceptionEditor` with no warnings in new/changed files; app build passes inside every QA run. |
| Unit/integration | `./scripts/test.sh --filter LookMatchTests`, `--filter AgentEngineTests`, `--filter AutoAdjustmentTests`, then full `./scripts/qa.sh` | **PASS by substitute.** Focused: `--filter "LookMatch\|AgentEngine"` 37 tests (36 run, real-shoot runner skipped without env); `AutoAdjustmentTests` 11/11 including the RW2 test. Full suite at each step commit: 334 → 338 → 344 → 352 → 354 → 365 → 365 → 368 tests, all passing, 26–27 skipped (opt-in real-media tests). Final head `4bbfe10`: **370 tests in 79 suites passed, 343 executed / 27 skipped**, app build passed (`64fae1e`: 369, 342 / 27). `./scripts/qa.sh` itself cannot run here (no `rg` binary), so its source-review step is **NOT VERIFIED**. |
| Runtime/UI | Run Look Matching on a real shoot: scenes shown, flags unselected, apply + one undo | **NOT VERIFIED** — not run in the app (computer control of the app was declined on 2026-10-18). A ready copy is at `~/Pictures/LM1-check/LM1-check.pmedit`. Store-level behavior (flagged unselected, apply selected as one undo step, undo restores all) is covered by `LookMatchStoreTests` |
| Media quality | Real family-portrait RW2 shoot: acceptance 8 counts | **PARTIAL; acceptance 8 NOT VERIFIED.** Analysis run on the real 2026-10-18 "Ivy 1 year" family shoot (221 RW2, copy on internal disk, the photographer's 4 existing edits as heroes). See "2026-10-18 real-shoot run" below. Missing: the photographer's kept/touched count (criterion ≥ 85%). The shoot had no window or flash frames, so the different-light half of criterion 8 was only exercised by the patio-vs-yard split |
| Performance | 8 GB M1, 100–200 RW2: total time and peak footprint vs. Auto baseline | **NOT VERIFIED** for the whole app. Test process on this 8 GB M1, 221 RW2 from internal disk: 216 s (0.98 s/photo) and 631 s (2.86 s/photo) in two runs; lifetime peak 510–519 MB vs. 321–388 MB after one Auto analysis |

### Real-shoot check procedure (acceptance 8, photographer)

1. Copy one family-portrait shoot (100–200 RW2, ideally with window, open shade and flash frames) to the **internal disk**, e.g. `~/Pictures/LM1-check/`. Work only on this copy.
2. Build and open the branch app: `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ./scripts/build-app.sh`, then `open PerceptionEditor.app`.
3. New project → Add Files in Place → select the copied folder's RW2 files. Save the project as `LM1-check.pmedit` next to the copy.
4. Cull as usual, then edit **one hero per lighting scene** in Photo. Note which frame you edited for each scene and which light it was (window / shade / flash). Save, then duplicate the `.pmedit` as `LM1-check-heroes.pmedit` (a snapshot for step 9).
5. Agents → Look Matching → Run Agent. Note the time shown from start to report (or use a stopwatch). Watch Activity Monitor → PerceptionEditor → Memory, and note the peak.
6. Record: number of scenes, scenes marked "needs a hero" (is the suggested frame sensible?), flagged count, "already edited" list. Check each scene: does it hold one light? Note any scene that mixes window, shade or flash frames, and whether those frames were flagged.
7. Leave flagged proposals unselected. Apply Selected. Press ⌘Z once and confirm every matched photo returns; press ⇧⌘Z to redo.
8. In Photo, step through every photo that received an **unflagged** proposal. Count the ones you keep with no slider change ("kept") and the ones you adjust ("touched"). Pass when kept ÷ (kept + touched) ≥ 85% and every mixed-light scene from step 6 was split or flagged.
9. Optional, for tuning: quit the app and run the analysis report on the hero snapshot:
   `PME_LOOK_MATCH_PROJECT=~/Pictures/LM1-check/LM1-check-heroes.pmedit PME_LOOK_MATCH_OUTPUT=~/Pictures/LM1-check/look-match-report.txt SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ./scripts/test.sh --no-parallel --filter realShootLookMatchReport -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing` The report lists each scene's split reason and each proposal's confidence, which shows which threshold to move.
10. Record the counts, time, peak memory, and any threshold changes in the Verification table and the thresholds table above.

## Decisions, discoveries, and remaining work

- 2026-10-18 (product owner): one hero edit **per scene**; cloud AI acceptable for the first year, local later (applies to LM4); **family portraits** are the first shoot type to tune and test against.
- Thresholds — **starting values; checked against one family-portrait shoot (2026-10-18, steady light, see below) without change. Not yet tested on a shoot with window, open-shade and flash light** (all in `LookMatchThresholds`):

  | Threshold | Default | Basis |
  | --- | --- | --- |
  | `captureGapSeconds` | 180 s | Frames within a pose are seconds apart; moving the family to a new spot takes minutes. Over-splitting only costs an extra hero edit, so err long. |
  | `miredStep` | 20 mired | Daylight 5500 K ≈ 182 mired, open shade 7500 K ≈ 133 mired (Δ ≈ 49), window/tungsten mixes further. AWB jitter under steady light is typically under ~10 mired. On the 16-file `110_PANA` sample, the as-shot steps that split were 44 mired. |
  | `exposureStep` | 1.0 EV | Scene EV (ISO 100) stays within a fraction of a stop under one light even when shutter/ISO change. Window vs. open shade is usually 2+ EV. A flash frame at sync speed reads differently from ambient frames. |
  | `featurePrintDistance` | 0.9 (unit-length prints, 0–2) | Lenient on purpose: content changes within a scene (pose, framing) should not split, and WB/EV catch light changes. Raise it if a scene fragments; lower it if a location change is missed. |
  | `minimumConfidence` | 0.6 | From the plan. |
  | `maximumExposureOffset` | 1.5 EV | From the plan. |
  | `maximumToneNudge` | 0.25 | From the plan. |
  | `percentileTolerance` | 0.03 (sRGB-encoded luma) | About 8 levels of 255 at the 2nd/98th percentile; smaller differences are not visible in a highlight/shadow comparison. |

- 2026-10-18 (implementation): survey feature prints and sharpness use the 512 px preview from `PhotoSourceLoader.loadThumbnail` (the camera's embedded JPEG for RAW) instead of a second 512 px RAW decode. Scene similarity and sharpness need no RAW engine output, and this saves one RAW decode per photo. The WB/exposure solve still uses a real 512 px decode through `MediaColorRenderer`.
- 2026-10-18 (implementation): Vision feature-print revision is the SDK default (macOS 15). Prints are normalized to unit length before comparison, so the threshold does not depend on the revision's scale. Re-check `featurePrintDistance` if the revision changes.
- 2026-10-18 (measurement, not a gate): timing on this 8 GB M1 for 16 copied S5 RW2s on internal disk, every photo solved against one hero (`PME_LOOK_MATCH_ONE_SCENE=1`): **0.6–3.4 s/photo across six runs**. Decoding dominated: the 512 px RAW decode took ~0.5–3.1 s, every other part ~0.2 s. Run-to-run variance was larger than any difference between Core Image context settings, so the analysis context keeps Auto's 128 MB target. With default thresholds the same 16 files ran in 3.0–4.5 s (3 scenes, 1 with a hero). Test-process lifetime peak footprint: 335–441 MB after one Auto analysis, 444–560 MB after Look Match, i.e. roughly Auto plus ~80–120 MB (feature-print model and buffers). These are test-process numbers, not the whole-app gate.
- 2026-10-18 real-shoot run ("Ivy 1 year", 221 RW2, 17 min of shooting in a sunny backyard plus a few patio frames; heroes = the photographer's 4 existing edits, carried from the schema-12 project into a disposable schema-10 copy — schemas 11–12 changed only video/audio fields):
  - Signals across the shoot: as-shot WB 202–224 mired, scene EV 10.0–12.0, longest pause 133 s. Consecutive feature distance median 0.20 (p99 0.81); distance to a scene's first frame median 0.97, so content distance mostly reflects pose and framing.
  - Grouping (default thresholds): 4 scenes. Scene 1 (2 frames, no edit → suggested P1107252), scene 2 (5 patio/dog frames, split on 1.3 EV, hero P1107254), scene 3 (1 frame, split on 1.7 EV and content), scene 4 (213 yard frames, hero P1107263). Visual check of contact sheets: scene 2 vs. the yard is a correct light change; scene 4 spans several setups (crate, blanket, solo portraits, family under the arch) in the same sun, with no light change the signals could see. Thresholds are therefore **unchanged**: this shoot gives no evidence to move them.
  - Confidence, first version: 181 of 215 flagged. Breakdown on a 32-frame slice: exposure residual mostly < 0.02 EV, but the whole-frame chroma term (0.12–0.37 against a full-penalty point of 0.12) took 0.30 off nearly every frame — it measured clothing and framing, not color cast. **Changed (`4bbfe10`)**: chroma compares neutral-area casts only, and the percentile term reaches full penalty at 0.4. Result: 214 of 215 unflagged. The one flagged frame (P1107259, a person walking through the frame) is a correct flag.
  - Visual check by the coding agent of all proposals rendered as contact sheets (`~/Pictures/LM1-check/sheets/`): exposure and color look consistent with each hero. Backlit, flared baby-on-blanket frames (P1107332–P1107353, about −0.4 EV) still look hazy and are the likeliest to be touched. This is an observation, not the photographer's kept/touched count.
  - Risk to watch: with no neutral area in most frames, confidence now rests mainly on the exposure residual and scene distance. A wrong-but-converged exposure (for example a frame dominated by bright sky) would not be flagged. The kept/touched count is the check on this.
- QA substitute: `./scripts/qa.sh` cannot run on this Mac because `rg` is not an installed binary. Every QA result here is `git diff --check` plus `scripts/test.sh --no-parallel` with SDK 26.5 and the Command Line Tools testing plugin path, in a clean worktree at the named commit.

### Follow-on milestones (separate ExecPlans when LM1 closes)

- **LM2 — Review grid and masks.** Before/after contact sheet sorted by confidence; approve all/scene/one. Re-detect subject and sky on each target and carry each mask's adjustment values, not its pixels. Skin-tone check: compare each face's skin color with the hero's and flag warm/green/magenta drift. Test families of 4+ early; group selection is a known weak spot (docs/archive/SELECTION_QUALITY_2026-10-08.md).
- **LM3 — Agent bridge (MCP).** Off-by-default localhost server with a token, plus an MCP wrapper. Tools: `list_shoot`, `get_adjustments`, `render_preview` (≤ 1024 px JPEG), `propose_look_match`, `apply_proposal`, `undo`. Every write still requires approval in the app. References: darktable-mcp (preview tool), Lightroom Classic MCP server (job queue + polling).
- **LM4 — AI review for flagged photos.** Send hero and target previews (≤ 1024 px) and current sliders to the Claude API; it returns bounded slider deltas; render, re-score, up to 3 rounds. Per-project off switch. Keep the model behind one protocol so a local mlx-vlm model can replace it after year one.
- **LM5 — Personal style model.** Log (proposed sliders, final sliders, image statistics) on every approval or correction; after a few hundred pairs, train a small Create ML regressor to predict corrections; evaluate on a held-out shoot against LM1.
