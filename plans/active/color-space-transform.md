# Milestone: Color Space Transform for V-Log and Apple Log

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax. Test first for every task.

Status: proposed 2026-10-17, not started. Builds on [video-10bit-color-pipeline.md](video-10bit-color-pipeline.md) (branch `plan/10bit-vlog-color`: OCIO-generated shaders, `ColorInputTransform`, Apple Log and V-Log input transforms, ACES 2.0 output).
Owner: video engine

## Scope

The owner uses **Panasonic V-Log / V-Gamut (Lumix S5)** and **Apple Log (iPhone 15 Pro)** only. No other camera spaces are added. Out of scope: HDR output (PQ/HLG), a mid-chain node, Display P3, any third camera.

## User-visible outcome

Like DaVinci Resolve's Color Space Transform, the photographer states what the footage is and what they want to see:

- **Input color space:** Auto (detected, as now), Panasonic V-Log / V-Gamut, or Apple Log / Rec. 2020. A manual choice overrides detection (a mis-tagged or unrecognised clip).
- **Output color space:** one setting for the project.
  - **ACES 2.0 SDR 100 nits Rec. 709** (the current look, with the ACES tone and gamut mapping).
  - **Rec. 709, gamma 2.4, no tone mapping** (Resolve's usual "V-Log to Rec.709 / Gamma 2.4" CST: a plain gamut and gamma conversion that clips what falls outside).
  - **sRGB** (gamma from the sRGB curve, no tone mapping), for stills-style display checks.
- The picker names the camera and says what each output does. The grade, LUTs and scopes behave as they do now.

## What exists

- `generate-shaders.py` builds one kernel per input transform and one output kernel from OpenColorIO built-ins, plus fused "input then output" kernels and golden data in `Tests/Fixtures/ocio-golden.json`. No OpenColorIO is linked.
- `ColorInputTransform` (`automatic`, `aces`, `lut`) is stored per clip in the project (`colorInputByAssetID`, schema 11); `resolvedOCIOInputs()` maps it to `OCIOInputTransform` (`.vLogVGamut`, `.appleLog`).
- The compositor's recipe carries `ocioInput`; the output transform is fixed to ACES 2.0 SDR Rec. 709.

## Tasks

### Task A: Simple output transforms in the generator

- [ ] Test first: new golden entries (PyOpenColorIO CPU outputs) for each camera into Rec. 709 gamma 2.4 and into sRGB, on seeded inputs and real-pixel samples, in `OCIOShaderTests`. They fail until the kernels exist.
- [ ] `generate-shaders.py`: add two output transforms built from OpenColorIO built-ins (ACES2065-1 to Rec. 709 linear, then the gamma 2.4 or sRGB encoding; no tone or gamut mapping beyond a clamp), and the fused input-then-output kernels for both cameras. Regenerate `OCIOGeneratedShaders.swift`.
- [ ] `OCIOColorKernels`: expose the new outputs next to the ACES output. The GPU must match OpenColorIO's CPU within the existing limit (G11 style).
- **Done when:** both outputs pass the GPU-versus-CPU suites for V-Log and Apple Log, and the existing V-Log and ACES goldens are unchanged value for value.

### Task B: Model and resolution

- [ ] Test first (`LUTWorkflowTests`, `ProjectPersistenceTests`): the output setting round-trips; an old project (schema 11) opens with the ACES output; a manual input choice overrides detection; a clip with an imported LUT is unaffected.
- [ ] Add `ColorOutputTransform` (`acesSDR`, `rec709Gamma24`, `sRGB`) as a project-level field decoded with a default, so schema 11 still opens. If decoding cannot be made backward compatible, bump to schema 12 and add the migration test.
- [ ] Extend `ColorInputTransform` with explicit `vLog` and `appleLog` cases (today `aces` means "the detected camera through ACES"). Migrate `aces` to a case that keeps its meaning.
- [ ] `resolvedOCIOInputs()` and the recipe carry the chosen output; export and preview read the same value.
- **Done when:** preview, source viewer, timeline and export all resolve the same input and output for a clip.

### Task C: Picker UI

- [ ] Test first: store-level tests for the choices a clip offers (an Apple Log clip offers Auto, V-Log, Apple Log; the output list is project-wide).
- [ ] Extend the existing source-color picker (`LUTControls`/inspector) with the input list and an output picker, with a one-line description each. Keep the LUT option as it is.
- [ ] In-app walkthrough on the target Mac: switch a V-Log and an Apple Log clip between the three outputs in the source viewer, on the timeline and on the scopes. Mark it NOT VERIFIED until done by eye.

### Task D: Export tagging

- [ ] Test first: an export with each output opens with the right color tags (`ExportColorTagTests` or the existing export suites).
- [ ] Rec. 709 gamma 2.4 is tagged as Rec. 709 primaries with the Rec. 709 transfer function and matrix, as the current export is. sRGB is tagged sRGB primaries and transfer if AVFoundation accepts it; if not, the sRGB output is preview-only and export falls back with a warning. Decide and record this in the decision record.

### Task E: Real gates

- [ ] **G14 correctness:** for real S5 and iPhone frames, the Rec. 709 gamma 2.4 and sRGB outputs against PyOpenColorIO on at least 6 000 real pixels per camera: worst error within the G11 limit. PASS/FAIL.
- [ ] **G15 performance:** the simple outputs are cheaper than ACES 2.0. Run the G12 chain (4K preview, export, proxy playback) on an internal-disk copy with each output. The simple output must not be slower than ACES, and the numbers go in `PERFORMANCE_TARGETS.md`. This milestone does not claim to fix G12 or G7.
- [ ] **G16 owner check:** the owner compares the three outputs on one V-Log clip and one Apple Log clip against DaVinci Resolve's CST (V-Log/V-Gamut to Rec. 709 Gamma 2.4, and Apple Log to Rec. 709), tone mapping off. NOT VERIFIED until the owner reports. Expect small differences: Resolve's CST uses its own gamut conversion and optional gamut mapping, so the result is judged by eye, not required to match.

## Files

Modify `scripts/ocio/generate-shaders.py`, `OCIOGeneratedShaders.swift` (regenerated), `OCIOColorKernels.swift`, `EditorModels.swift`, `EditorStore+LUTs.swift`, `LUTControls.swift`, `TimelineCompositionService.swift`, `TimelineExporter.swift`, `Tests/Fixtures/ocio-golden.json`, `docs/ARCHITECTURE.md`, `docs/DATA_MODEL.md`, `docs/TESTING_STRATEGY.md`. Create `docs/decisions/2026-10-xx-color-space-transform.md`.

## Risks

| Risk | Handling |
| --- | --- |
| A simple output clips highlights that ACES 2.0 would roll off, so V-Log highlights look harsh. | Name this in the picker. ACES stays the default. |
| sRGB output in a Rec. 709-tagged file looks different in other players. | Task D decides tagging; sRGB may stay preview-only. |
| The grade runs between input and output, so a different output changes grade behaviour. | The grade still runs in the same working space; only the final stage changes. Golden tests cover grade-then-output for each. |
| Old projects must keep their look. | Task B's migration test; default stays ACES. |
| G12 and G7 still fail, and a new output adds a kernel. | G15 measures; no new work is promised on memory or throughput here. |
