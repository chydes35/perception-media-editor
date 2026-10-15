# Real-photo selection quality validation

Status: active
Roadmap item: [Phase 3 selection quality and Phase 4 acceptance](../../docs/ROADMAP.md)
Owner: lead Codex agent

## User outcome and acceptance

Inspect real RAW subject/sky masks, fine boundaries and edited exports on the M1/8 GB target Mac. Produce repeatable local evidence without treating a successful inference or a few sampled points as broad photographic acceptance. A genuine 100–200-file shoot remains pending the user's folder path.

## Current state and affected contracts

Start at `79310cc`, clean checkout, passing local and GitHub QA. Existing native fixtures cover one two-person JPEG, indoor sky rejection and one RAW portrait. This step adds an opt-in quality evidence runner using disposable RAW copies, saved raster masks and the production renderer. No schema or application behavior change is planned.

## Implementation steps

1. Select visually examined RAW fixtures covering group/portrait/fur/fabric/fine branches.
2. Run native subject/sky inference sequentially; save masks, overlay previews, edited exports and per-fixture observations.
3. Inspect outputs and record limitations; preserve open hair/translucency/sunset/reflection/mixed-camera gates.
4. Run focused/full applicable QA and document reproducible invocation. Check original/copy integrity.

## Safety and performance

Fixtures are read-only disposable copies from the prior hashed workload. Outputs stay under external-SSD `.build/selection-quality-validation`; no media is uploaded. One inference/render fixture at a time, no retained full-size output buffers. Timings are diagnostics, not agreed performance thresholds.

## Verification

| Gate | Required check | Result |
| --- | --- | --- |
| Static/build | Diff/source checks and Swift build | PASS — full QA/debug build |
| Unit/integration | Opt-in runner and applicable QA | PASS — 296 reported/291 executed/five skipped, 59 suites, 140.894 s |
| Runtime/UI | Previously validated app behavior; new displayed cases if defects require it | NOT VERIFIED for this step |
| Media quality | Inspect native masks/exports; distinguish structural from quality results | Structural PASS; sampled quality FAIL — group/branch-sky; portrait spill. See report |
| Performance | Sequential timings; genuine shoot/thresholds | NOT VERIFIED — shoot path pending |

## Decisions and remaining work

Do not add inferred quality pass assertions based only on nonempty masks. Capture inference errors as explicit observations. Whole-shoot and broad quality milestones remain active.

Six cases/five distinct RAW copies generated structural evidence. Repeated inference timings, inspected artifacts and limitations are in the [October 8 report](../../docs/archive/SELECTION_QUALITY_2026-10-08.md). Source integrity PASS for five originals/copies. Keep the plan active: demonstrated group/sky misses need bounded implementation work and annotated references; genuine-shoot path is still pending.

### Subject edge probe: guided filter — October 15

Hypothesis: the existing `SkyEdgeRefiner` guided filter (luminance guide, 1536 px) would reduce subject-mask spill and recover fine hair. `SubjectEdgeProbeTests` (opt-in: `PME_EDGE_PROBE_INPUTS` comma-separated files, `PME_EDGE_PROBE_OUTPUT`) writes each photo with the union mask as an overlay for the base mask and for radius 8 / 16, epsilon 1e-3. Nine S5 files (P1107136-144, read-only originals converted to DNG outside the repository), inspected on P1107138 (adult and child, group candidates) and P1107144 (portrait, hair, orange skirt on grey carpet).

Result: **hypothesis fails.** On hard fabric edges the base Vision mask is already tight; the filter adds a soft halo onto the carpet (radius 16 worst, radius 8 visible on zoom), which is more spill, not less. On hair, the base mask misses bright flyaway wisps at the top of the head; the filter recovers only a little of them, mostly at radius 16. Net: no integration. Fine hair and translucency need a different approach (a matting step against the image, or a model with alpha), not a luminance filter on the binary-ish mask. Production code is unchanged; no gate beyond the visual inspection was run, and this is two photos, not broad acceptance.

Environment notes: after the October 15 macOS update (a) the RAW decoder asset was missing and its download fails inside `mobileassetd`/`nsurlsessiond`, so RAW cannot decode in any app until macOS is repaired; Adobe DNG Converter 18.7 was used for DNG copies; (b) Command Line Tools now default to the macOS 27 SDK, which lacks the SwiftUI macro plugin. Build and test with `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk` and add `-Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing` to `./scripts/test.sh`.

### Edge matting integrated — October 15

`SubjectEdgeMatting` (new) refines each subject candidate mask after analysis: in a band of 10 px (1536 px working size) around certain foreground (weight >= 0.97), each pixel's opacity is its position on the color line between the nearby foreground and background colors; ambiguous (low color contrast) pixels keep the model weight, and pixels the model scored 0 are only raised when a lightly smoothed matte exceeds 0.5 (texture can fake a wisp). The refined matte is upscaled back to each candidate's PNG size; candidate ids, names, pixel counts and label maps are unchanged. Saved raster masks keep their format (schema 10).

Evidence (nine S5 photos as DNG copies; inspected P1107144 portrait, P1107138 adult and child): hair wisps the model missed are recovered, the orange skirt edge stays tight with no carpet halo (the guided filter's failure), and faint spill below the adult's legs is reduced. A first variant that rescued every zero-weight pixel added carpet speckle, so the smoothed 0.5 floor was added. Five synthetic tests (`SubjectEdgeMattingTests`: wisp recovered, soft boundary snaps to the color edge, certain regions unchanged, similar colors keep the model mask, bad input unchanged) pass.

| Gate | Result |
| --- | --- |
| Unit | PASS — 330 tests, 323 pass; 7 RAW-decode tests FAIL because macOS cannot decode RAW on this Mac (see environment note above), not because of this change |
| Media quality | Visual PASS on 2 photos (hair, hard fabric edge, spill); NOT VERIFIED broadly — no ground truth, no translucency/fur/sunset cases |
| Performance | Release build, one 1536 px candidate: 0.23 s (debug 16 s); memory about 40 MB working arrays. Whole-analysis latency/footprint NOT VERIFIED |
| Runtime/UI | NOT VERIFIED — the app could not decode RAW; displayed selection, save/reopen and export not rechecked |
| Causal | Not run: the synthetic wisp test fails with `rescueMissed` off |

Remaining: UI/save/export recheck after RAW decoding works again, fur/translucent fabric controls, and the group and sky misses.
