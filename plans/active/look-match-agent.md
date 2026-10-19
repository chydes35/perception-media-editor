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
3. **Exposure metadata.** Add an analysis-time reader for ISO, exposure time and f-number (ImageIO EXIF), returning an exposure value. Do not add fields to `MediaAsset`.
4. **Scene grouping** — new `LookMatchScenes.swift`: `SceneSignal` (asset ID, capture date, as-shot mired, EV, feature print) and a pure `group(_ signals:, thresholds:) -> [[UUID]]`. Feature prints come from `VNGenerateImageFeaturePrintRequest` on the 512 px decode.
5. **Analyzer** — new `LookMatchAnalyzer.swift` plus `actor LookMatchService`: hero stats once per scene, then the per-target WB and exposure solve and confidence (acceptance 4–5). One 512 px decode alive at a time; check `Task.checkCancellation()` between photos.
6. **Models.** Add `AgentChangeKind.matchLook`. Add optional `proposedAdjustments: PhotoAdjustments?`, `confidence: Double?`, `sceneIndex: Int?`, `isSelected: Bool` (default true) to `AgentChange`, decoded with `decodeIfPresent`.
7. **Store** — new `EditorStore+LookMatch.swift`: `startLookMatch()` / `cancelLookMatch()` following `EditorStore+Auto.swift` (request ID, project generation, discard stale results, progress in `statusMessage`). Route the Look Matching agent's Run button here. Extend `applyLatestAgentChanges()` to apply only selected `.matchLook` changes, using `proposedAdjustments` but re-checking the target is unchanged since analysis; skip and report any target edited in the meantime.
8. **UI** — `AgentWorkspace.swift`: for Look Matching, show scenes with hero name, a row per proposal (thumbnail, filename, confidence, flagged badge, checkbox), "already edited" and "needs a hero" findings, and Apply Selected / Cancel.
9. **Tests** — new `LookMatchTests.swift`, extending `AgentEngineTests` where it fits:
   - grouping splits on each signal independently and is stable for identical input;
   - a fixture darkened by 1 EV solves to exposure ≈ +1.0 (±0.1);
   - RAW WB offset is carried in mired (unit test on the math, plus a RAW fixture when local samples exist);
   - edited targets and geometry/brush/retouch are never overwritten;
   - unselected proposals are not applied; apply is one undo step; undo restores all;
   - stale results after project replacement are discarded; cancellation leaves the project unchanged;
   - old `AgentReport` JSON without the new fields still decodes;
   - originals' bytes are unchanged (existing `TestSupport` fixtures).
10. **Docs.** Update `docs/AGENTS.md`, `docs/CURRENT_STATUS.md`, and add a Phase 2 roadmap line for per-scene look matching. Record tuned thresholds and gate results here.
11. **Gates.** `./scripts/qa.sh`, then the real-shoot check (acceptance 8) on the 8 GB M1.

## Safety and performance

- Originals are read only; analysis decodes at 512 px. Apply changes project metadata only, through the existing undo/history path.
- Analysis runs off the main actor in its own actor, never on `PhotoRenderer`'s, so editing previews stay responsive. Respect cancellation, project generation and memory-pressure callbacks; clear Core Image caches after each photo as Auto does.
- Peak memory target: no more than the Auto analyzer's budget plus feature-print buffers for one photo. Measure with `scripts/profile-memory.sh` or Instruments on the target Mac and record it. Do not claim a pass without the measurement.
- Expected time: about 150 decodes at 512 px plus up to 3 renders each; record actual seconds for a 150-photo shoot.

## Verification

| Gate | Required check | Result and evidence |
| --- | --- | --- |
| Static/build | `git diff --check`; Swift build | PENDING |
| Unit/integration | `./scripts/test.sh --filter LookMatchTests`, `--filter AgentEngineTests`, `--filter AutoAdjustmentTests`, then full `./scripts/qa.sh` | PENDING |
| Runtime/UI | Run Look Matching on a real shoot: scenes shown, flags unselected, apply + one undo | PENDING |
| Media quality | Real family-portrait RW2 shoot: acceptance 8 counts | PENDING |
| Performance | 8 GB M1, 100–200 RW2: total time and peak footprint vs. Auto baseline | PENDING |

## Decisions, discoveries, and remaining work

- 2026-10-18 (product owner): one hero edit **per scene**; cloud AI acceptable for the first year, local later (applies to LM4); **family portraits** are the first shoot type to tune and test against.
- Thresholds: PENDING tuning on a real shoot.

### Follow-on milestones (separate ExecPlans when LM1 closes)

- **LM2 — Review grid and masks.** Before/after contact sheet sorted by confidence; approve all/scene/one. Re-detect subject and sky on each target and carry each mask's adjustment values, not its pixels. Skin-tone check: compare each face's skin color with the hero's and flag warm/green/magenta drift. Test families of 4+ early; group selection is a known weak spot (docs/archive/SELECTION_QUALITY_2026-10-08.md).
- **LM3 — Agent bridge (MCP).** Off-by-default localhost server with a token, plus an MCP wrapper. Tools: `list_shoot`, `get_adjustments`, `render_preview` (≤ 1024 px JPEG), `propose_look_match`, `apply_proposal`, `undo`. Every write still requires approval in the app. References: darktable-mcp (preview tool), Lightroom Classic MCP server (job queue + polling).
- **LM4 — AI review for flagged photos.** Send hero and target previews (≤ 1024 px) and current sliders to the Claude API; it returns bounded slider deltas; render, re-score, up to 3 rounds. Per-project off switch. Keep the model behind one protocol so a local mlx-vlm model can replace it after year one.
- **LM5 — Personal style model.** Log (proposed sliders, final sliders, image statistics) on every approval or correction; after a few hundred pairs, train a small Create ML regressor to predict corrections; evaluate on a held-out shoot against LM1.
