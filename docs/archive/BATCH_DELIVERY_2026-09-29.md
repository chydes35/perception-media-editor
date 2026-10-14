# Batch delivery MVP verification — September 29, 2026

## Delivered

The Export workspace now exports the selected photos in project order as sRGB JPEGs. The recipe sets JPEG quality, full resolution or a 2,048/3,000/4,000-pixel long edge, and a safe filename suffix. The queue shows progress, Stop, and per-file results. Existing outputs and project originals are protected; unique numbered names are planned, and final publication refuses a destination created during rendering. The existing single-photo JPEG/PNG action remains available.

## Automated evidence

| Check | Result |
| --- | --- |
| Auto Tone baseline repro | Failed with the original contrast proposal, passed with the fix, failed on temporary revert, passed after restoration. |
| Focused batch tests | Six passed: recipe validation, protected/original names, existing/late collisions, resize without upscaling, ordered store results, and pre-start cancellation. |
| Full QA | `./scripts/qa.sh` passed: 247 tests in 43 suites, app build, source reviewer, and diff check. |
| Signed bundle | `./scripts/build-app.sh` and `codesign --verify --deep --strict PerceptionEditor.app` passed. |

An earlier parallel full-suite run timed out three ingest tests while render and import work competed. The ingest suite passed alone. Two explicit `--no-parallel` full-suite runs passed; the standard QA script and CI now use that mode. Local logs are under `.build/` and are not project data.

## Real RAW UI check

On the 8 GB M1 MacBook Air, added two distinct Lumix S5 RW2 files by reference, selected both, chose 2,048 px, and exported to a disposable folder. The app reported **2 saved, 0 failed**. Both JPEGs decoded at **2,048 × 1,366** pixels. One output was visually inspected and appeared intact. Repeating export to the same folder produced `-2` names; checksums of the first outputs were unchanged. A third run stopped during the first RAW render and reported **0 of 2 complete**; no additional output file appeared.

## Open acceptance

This verifies the two-photo workflow and basic real-RAW output, not complete delivery readiness. The active [ExecPlan](../../plans/active/batch-delivery-mvp.md) still requires a distinct 100–200-photo run with throughput and whole-app footprint measurements, broader preview/export color comparison, and mixed failure recovery. Persistent recipes, metadata/IPTC, watermark, sharpening, P3, and video export are later roadmap work.
