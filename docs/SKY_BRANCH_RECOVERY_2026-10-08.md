# Sky gaps through branches — October 8, 2026

This follows the [initial selection review](SELECTION_QUALITY_2026-10-08.md) and [failed crop experiment](GROUP_SELECTION_RECOVERY_2026-10-08.md). The change improves clear blue gaps in one recorded RAW. Phase 3 and broad quality/performance acceptance remain active.

## Cause and bounded recovery

On copied `005_P1000132.RW2`, the bundled model labels 191,335 of its 448 × 448 pixels as tree, 5,394 as grass and only 3,975 as sky. The four clear missed gaps are all labeled tree. Its sole output is an integer class map, so no class probabilities are available to recover uncertain sky. Luminance-guided filtering alone cannot restore these absent labels.

`SkyBranchRecovery` learns normalized red/green color from at least 24 strongly selected blue-sky pixels. It requires blue dominance and sufficient brightness, then adds matching color only in model-labeled tree regions above the last confirmed blue-sky row plus 10% of frame height. Color confidence fades across a normalized chromatic-distance band of 0.04–0.08. Blue dominance, brightness and spatial limits are conservative engineering choices; they are not trained confidence values or accepted quality thresholds.

The existing guided mask is retained, and recovered pixels pass through the same guided edge filter. Their result is combined by maximum with the original guided mask, so recovery cannot remove existing coverage. No additional model inference runs. Processing remains on the sky actor with 1,536-pixel bounds, sequential arrays and cancellation checks; native inference and guided filtering cannot be interrupted mid-call. Core Image contexts now clear their caches on exit and use a 128 MiB allocation target. That is not a process-memory ceiling.

No sky labels still means `noSky`. No eligible tree region or blue-sky anchors means the prior result. Saved raster masks remain schema 10, with the existing brush/edge refinement and photo/video rendering contract. No model download or original-media writes are needed.

## Annotated evidence and limitations

Coordinates are normalized, top-left oriented source coordinates. Before/after mask samples use 0–255 coverage.

| Point | Annotation | Before | After |
| --- | --- | --- | --- |
| (0.62, 0.04) | Clear sky gap | 0 | 253 |
| (0.44, 0.12) | Clear sky gap | 0 | 235 |
| (0.48, 0.16) | Clear sky gap | 0 | 213 |
| (0.52, 0.10) | Clear sky gap | 0 | 255 |
| (0.063, 0.45) | Wood | 0 | 0 |
| (0.11, 0.13) | Wood | 0 | 0 |
| (0.23, 0.17) | Dark foreground/background | 0 | 0 |
| (0.5, 0.8) | Lower foreground | 0 | 0 |
| (0.32, 0.035) | Shaded ambiguous gap | 0 | 23 |

The initial four-point hypothesis included the shaded point and failed its >150 coverage expectation. It stays an unresolved observation; the regression covers four visually clear gaps and four background/wood controls. Do not treat the shaded point or fine-edge quality as fixed.

This recovery targets similar blue sky around trees. Overcast sky, sunsets, heavily shaded gaps, lower gaps outside the band, and vegetation with unusual blue colors are not established improvements. A blue object misclassified as tree and resembling sky could be included. Semantic blue-object exclusion is tested with a portable positive-sky fixture; real blue fabric without sky is rejected. Varied real outdoor blue objects/reflections with sky remain unverified. Brush correction remains necessary for difficult edges and spill.

## Verification

- **PASS — focused reproduction:** `PME_SKY_BRANCH_INPUT=<copied RAW> PME_SKY_NEGATIVE_MANIFEST=<three paths> PME_SKY_BASELINE_MASK=<prior mask> PERCEPTION_SKY_MODEL_PATH=<pinned model> ./scripts/test.sh --no-parallel --filter SkyBranchRecoveryTests`. Checks clear gaps, wood/background points, preserved previous coverage, portable blue-object/lower-blue/no-anchor controls, pre-canceled recovery, and native no-sky rejection for indoor group, blue-fabric and portrait RAWs.
- **PASS — causal failure:** restore pre-change `SkyAnalyzer` temporarily; all four clear-gap expectations fail at zero coverage. Restore the correction and rerun the same test. Logs: `/private/tmp/perception-sky-branch-causal-red.log` and `/private/tmp/perception-sky-branch-causal-green.log`.
- **PASS — full local QA:** `./scripts/qa.sh`, 305 reported cases / 64 suites, **299 executed / six skipped**, 140.369 seconds, source/diff checks and debug build. Annotated sky/group RAWs, eight-case selection manifest, saved RAW healing project and native two-person/indoor-sky fixtures enabled. Skips: broad Auto comparison, two mask diagnostics, isolated RAW memory diagnostic, sky crop probe and separate outdoor-sky fixture. Log: `/private/tmp/perception-sky-branch-full-qa.log`. A later fixture-generator metadata correction passes the focused annotated test and debug build; production code is unchanged after full QA.
- **PASS — production media artifacts:** inspect the eight-case runner's sky overlay and edited export in `.build/sky-branch-recovery/final-artifacts/02`. Clear gaps gain coverage; other branch gaps and soft transitions still need refinement. All pre-existing subject candidate PNGs remain byte-identical to the group-recovery artifacts. Indoor group, blue fabric and portrait produce no sky. Raster round-trip and 2,048-pixel production export checks pass.
- **PASS — isolated release UI / packaging:** release build, ad-hoc deep signature and plist checks. On M1/8 GB / macOS 26.6.2, Select Sky displays the recovered gap overlay. Save/reopen preserves `Sky 1`; saved PNG is byte-identical to the tested mask. Full-resolution JPEG export completes at **4,000 × 5,328**, matching oriented source metadata, and fully decodes through `sips -s format png`. The disposable project generator now reads actual source dimensions rather than a hardcoded guess. The installed app is not replaced.
- **PASS — media integrity:** all five originals and five disposable RAW copies match pre-run SHA-256; `.build/sky-branch-recovery/integrity.json`. Sources remain read-only.
- **PASS — target-Mac observations only:** `footprint -p <candidate PID> -f bytes --noCategories --sample 2 --sample-duration 300`, with additional reads after export/replacement. Lifetime physical peak **876,302,208 B (835.7 MiB / 0.82 GiB)**, **328,208,064 B (313.0 MiB)** after export, **231,280,064 B (220.6 MiB)** after project replacement. The one-photo run is not comparable to the earlier group or 100-photo runs. Debug manifest sky analysis takes 11.952 seconds; UI completion was observed without instrumenting exact latency.
- **NOT VERIFIED — performance acceptance and broader photographic quality:** no matched baseline/threshold comparison, genuine single-shoot gate, varied real sky with blue objects/reflections, overcast/sunset, or complete edge-quality acceptance. Recovery adds bounded color/eligibility arrays and a second guided filter when new pixels are found; no extra model predictions. Next expand annotated positive/negative sky coverage and reduce edge spill, alongside remaining group recovery.

Local diagnostic `SkyBranchProbeTests` accepts `PME_SKY_BRANCH_INPUT`, `PME_SKY_BRANCH_OUTPUT` and `PERCEPTION_SKY_MODEL_PATH`. It reports class counts/point labels and saves class/recovery masks; successful execution is not a photographic-quality verdict. Artifacts stay under `.build/sky-branch-recovery`, outside tracked source. No private media is uploaded.
