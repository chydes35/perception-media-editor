# Group selection recovery — October 8, 2026

This follows the [sampled selection review](SELECTION_QUALITY_2026-10-08.md). It improves one demonstrated group case; Phase 3 quality acceptance stays active.

## Change and limits

Full-frame Vision person labels claim the two smaller standing people in `001_P1107136.RW2`, while the corresponding scaled editable mask contains only the foreground child. Using those labels to suppress recovery reproduced the omission. Recovery now checks actual offered mask coverage at detected upper-body centers.

A human detector identifies small upper-body boxes (confidence at least 0.6, normalized area below 0.03). Up to three missing areas are processed sequentially with accurate person segmentation on expanded crops. Native candidate pixels are excluded from recovered masks. Native candidate PNGs retain their identity; supplemental masks supply picking labels before unreliable coarse native labels. These bounds are engineering choices, not agreed quality or latency thresholds.

The fixture now offers `Person 1` and two `People in area` selections. The area names reflect possible neighboring-person inclusion. The standing girl and boy can be picked independently and have positive editable coverage. Other group members remain missed, and crop masks have soft spill. This does not establish complete group separation or fine-edge acceptance.

Inference remains on the subject-analysis actor, on the existing oriented 3,072-pixel source. Each crop and mask is handled sequentially, with cancellation checks between native requests and cache cleanup. Cancellation cannot interrupt an in-flight Vision request. Raster mask persistence stays schema 10; no source media or model changes are required.

## Evidence

- **PASS — annotated real-RAW reproduction:** `PME_GROUP_PROBE_INPUT=<copied RAW> ./scripts/test.sh --no-parallel --filter GroupRecoveryTests`. Girl `(0.243, 0.52)` and boy `(0.865, 0.50)` resolve to different recovered selections with mask values above 150/255. Cross-person coverage stays below 50/255. The existing foreground child stays a native person. Ceiling and open-floor controls remain unselected with mask values below 50/255.
- **PASS — causal check:** temporarily disable the recovery call; the same RAW test fails four assertions (kind, identity, and both coverage points). Restore the call and rerun: two focused tests pass. Logs: `/private/tmp/perception-group-causal-red.log` and `/private/tmp/perception-group-causal-green.log`.
- **PASS — visual partial improvement:** inspect recovered masks and union overlay in `.build/group-selection-recovery/coverage-artifacts/01`. Two smaller people are recovered without replacing the existing child mask. Remaining group omissions and soft crop spill prevent a broad quality pass.
- **PASS — full local automated QA:** `./scripts/qa.sh` with group probe, six-case selection manifest, saved RAW healing project, pinned sky model and native two-person fixture. 300 reported tests / 62 suites, **294 executed / six skipped**, 114.022 seconds; source/diff checks and debug build pass. Skips: broad Auto comparison, two mask diagnostics, isolated RAW memory diagnostic, sky crop probe (run separately), outdoor-sky fixture. Log: `/private/tmp/perception-group-full-qa.log`.
- **PASS — repeated fixture comparison:** all four pre-existing native candidate PNGs (group, dog, fabric, portrait) are byte-identical to the earlier artifacts. The group adds two candidates; the other subject cases keep one each. Indoor sky remains rejected. Structural raster round-trip and production preview/export checks pass on all positive manifest cases.
- **PASS — isolated release UI on M1/8 GB / macOS 26.6.2:** release build plus ad-hoc deep signature and plist checks. One-photo disposable project shows three candidates; clicking the girl in the image and adding the boy from the list creates two masks. Save/reopen displays both. Saved PNGs are byte-identical to the tested recovered candidates. A full-resolution 6,000 × 4,000 JPEG export completes and fully decodes via `sips -s format png`. The installed app was not replaced.
- **PASS — read-only media integrity:** all five originals and five disposable RAW copies match their pre-run SHA-256. Local evidence: `.build/group-selection-recovery/integrity.json`.
- **PASS — performance observation only:** `footprint -p <candidate PID> -f bytes --noCategories --sample 2 --sample-duration 300` observes lifetime physical peak **1,216,253,632 B (1,159.9 MiB / 1.13 GiB)**, **311,807,936 B (297.4 MiB)** after export and **206,016,192 B (196.5 MiB)** after project replacement. This one-photo run is not a matched before/after comparison or a whole-shoot acceptance test. Native inference peak memory is additional to the Core Image allocation target.
- **NOT VERIFIED — agreed performance thresholds / broad photographic quality / full-shoot acceptance:** group analysis in the warmed six-case run takes 3.149 seconds, versus 7.189 seconds in an earlier separate process. These are observations with different warmup conditions. Every subject analysis adds human detection and materializes actual mask coverage; missing areas can add up to three sequential segmentations. Do not infer an accepted latency ceiling from these samples.

## Branch-heavy sky experiment

`SkyCropProbeTests` accepts `PME_SKY_CROP_PROBE_INPUT`, `PME_SKY_CROP_PROBE_OUTPUT`, and `PERCEPTION_SKY_MODEL_PATH`. Four overlapping 60%-frame crops use the existing model, sequentially, with mask union materialized after each crop. This diagnostic is opt-in and does not change production sky inference.

**FAIL — photographic improvement:** on copied `005_P1000132.RW2`, three crops return no sky and one returns a smaller upper-right sky patch. The resulting union still misses branch gaps and loses some previously detected sky. Diagnostic execution passes (5.531 seconds), but its quality hypothesis fails. Crop inference observations are 0.583, 0.199, 0.210 and 2.194 seconds; they are not app-interaction measurements or accepted limits. Artifacts: `.build/group-selection-recovery/sky-crops`; log: `/private/tmp/perception-sky-crop-probe.log`.

Next investigate a stronger source of sky labels with branch-gap annotations and indoor/blue-object negative controls. Guided edge refinement cannot fill large regions absent from model labels. Do not ship this crop experiment as a quality fix.
