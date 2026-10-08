# Sky gaps through branches

Status: active
Roadmap item: [Phase 3 mask quality](../../docs/ROADMAP.md)

## User outcome and acceptance

Improve the recorded missed blue-sky gaps without selecting wood, clothing, indoor surfaces or reflected blue objects. Preserve existing sky coverage and saved raster masks. Acceptance requires annotated RAW foreground/background checks, negative controls, inspected preview/export, causal verification and full QA. Broad sky quality and agreed performance/full-shoot acceptance remain separate open gates.

## Current state and affected contracts

Start clean at `4f55ea6`. The bundled semantic model uses a 448-square input and outputs class labels. Four overlapping crops lost sky coverage. `SkyAnalyzer` detects exact sky labels, then luminance-guided refinement on a 1536-pixel source; that filter cannot recover absent sky labels. `.pmedit` schema 10 stores portable raster masks.

## Implementation steps

1. Inspect semantic classes at annotated missed gaps and retained sky.
2. Probe conservative recovery anchored to real sky colors and eligible semantic vegetation regions. Reject inference-free global blue selection. Use blue-object/indoor controls and bounded spatial/color evidence.
3. Integrate only if measured improvement survives controls; otherwise preserve the diagnostic and record why its hypothesis fails.
4. Focused causal regression, full QA, isolated release UI/save/export, original/copy hashes and target-Mac observations. Update status and PR evidence.

## Safety and performance

Use read-only disposable RAW copies; all artifacts/caches stay on external SSD. Keep inference and pixel processing on the sky actor, bounded to 1536 pixels, with cancellation checks and sequential model work. No model download, schema migration or installed-app replacement is planned. Record additional allocation/latency rather than inventing a performance ceiling.

## Verification

| Gate | Check | Result |
| --- | --- | --- |
| Static/build | Diff/source review; Swift debug/release builds | PASS — see report below |
| Unit/integration | Annotated real RAW, negative controls, causal revert, full QA | PASS — see report below |
| Runtime/UI | Isolated release selection, save/reopen, export | PASS — see report below |
| Media quality | Inspected gaps/branches and blue-object/indoor controls | PASS — sampled clear gaps and blue-object points; FAIL — white bow/fine gaps; NOT VERIFIED — reflected sky |
| Performance | M1/8 GB operation timing and process footprint | Observations PASS; thresholds / matched baseline NOT VERIFIED |

## Progress and discoveries

The previous four-crop experiment reduced detected sky. First inspect exact semantic labels before deciding whether constrained recovery is justified.

The model labels all four clear missed gaps as trees and exposes only integer classes. Sky-color recovery inside tree regions near the confirmed sky band recovers four clear gaps while preserving the existing mask. A shaded point fails the >150 coverage hypothesis (23/255) and remains unresolved; the regression uses visually clear annotations and records that limit.

Portable blue-object/no-anchor/wood/lower-blue and cancellation controls pass. Three real no-sky RAW controls remain rejected. Restoring old analysis fails four annotated assertions; restoring the change passes. Full QA: 299 executed/six skipped of 305, 140.369 seconds. Existing subject PNGs are unchanged. Release UI/save/reopen/full-resolution export decode and source hashes pass. Fixture metadata generation was corrected and focused-tested after full QA; production code is unchanged. Observed physical peak 0.82 GiB, post-replacement 220.6 MiB. See [complete evidence](../../docs/SKY_BRANCH_RECOVERY_2026-10-08.md).

Keep active for varied real blue-object/reflection/lighting controls, edge-quality and agreed performance/full-shoot acceptance. Next expand those annotations and reduce spill, alongside remaining group coverage. No model download or schema change was needed.

### Expanded controls — October 8, starting at 76a0c69

Inspect contact sheets of the 100 existing disposable RAW copies. Add outdoor blue blanket, shirt, sweatshirt, blue hat with overcast sky, woodland gaps, and a blue dress beside windows. Record actual mask weights at visually annotated points and inspect production preview/export artifacts before assigning quality results. The collection has no clearly identified water/reflection fixture; that acceptance remains unverified. Compare any failure against the pre-recovery analyzer before changing production behavior, so a pre-existing model error is distinguished from recovery spill. Keep original/copy hashes and run focused checks followed by full QA for test/code changes.

Expanded controls pass six RAWs and sixteen annotated points (four sky / twelve foreground), including outdoor blue clothing and overcast sky. Two no-sky outdoor controls are rejected. A white hair bow measures 222/255 in both old/current initial masks and remains a pre-existing foreground-selection failure. Complete fine gaps and actual reflected-sky controls remain open. Production code is unchanged; see [expanded evidence](../../docs/SKY_QUALITY_CONTROLS_2026-10-08.md).

Expanded full gate: `./scripts/qa.sh` PASS, 306 reported / 300 executed / six skipped in 65 suites, 231.823 seconds. Focused controls PASS, 63.372 seconds. All changed-document links and diff checks pass. No fresh UI or footprint check for unchanged production code; those broader acceptance gates remain open.
