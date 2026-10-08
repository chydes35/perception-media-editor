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

Six cases/five distinct RAW copies generated structural evidence. Repeated inference timings, inspected artifacts and limitations are in the [October 8 report](../../docs/SELECTION_QUALITY_2026-10-08.md). Source integrity PASS for five originals/copies. Keep the plan active: demonstrated group/sky misses need bounded implementation work and annotated references; genuine-shoot path is still pending.
