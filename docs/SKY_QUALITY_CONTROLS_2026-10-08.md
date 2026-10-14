# Expanded real-RAW sky controls — October 8, 2026

Starting revision: `76a0c69`, on the photo workflow integration branch. This task adds annotated local regression evidence; production selection code, model, project schema and installed app are unchanged. Phase 3 remains active.

## Fixtures and method

Inspected contact sheets of the existing 100 disposable S5 RAW copies. Selected six controls: `003_P1095908` (blue blanket against greenery), `010__1000868` (blue shirt/canopy with visible sky), `014__1002582` (woodland gaps), `022_P1095821` (blue dress beside windows), `052__1000872` (blue sweatshirt beside a building), and `099_P1000282` (blue hat against overcast sky). Six original files and six copies match the SHA-256 inventory. Inputs stayed read-only; artifacts stay on the external SSD under `.build/sky-quality-expansion/` and are not uploaded.

The pinned bundled model runs sequentially on the M1/8 GB Mac. The existing selection diagnostic generated before/mask/35% overlay, -1 EV masked previews and 2,048-pixel production exports, with raster JSON round-trip checks. These artifacts were visually inspected. A second run temporarily restored `SkyAnalyzer` from `4f55ea6` using a restoration trap; the current production file was restored afterward. Both artifact runs passed structurally (75.581 and 80.846 seconds). Their completion is not a whole-mask quality pass.

`SkyQualityControlTests` takes an annotated manifest through `PME_SKY_CONTROL_MANIFEST`, output through `PME_SKY_CONTROL_OUTPUT_DIR`, and the pinned `PERCEPTION_SKY_MODEL_PATH`. Each fixture specifies `name`, `path`, `expectNoSky`, and `points` containing a name, normalized top-left x/y, and inclusive minimum/maximum mask weights. Optional `baselineMaskPath` records increases/decreases against a separate analyzer run; it checks matching dimensions but does not assert pixel monotonicity across independent inference runs. All accepted points were chosen by viewing source images before adding assertions. The white-bow failure described below is outside the passing blue-object point checks and remains an open quality gate.

## Reproducible annotations

Coordinates refer to the oriented source, normalized from its top-left. The four sky assertions accept 151–255; the twelve foreground assertions accept 0–49. Focused execution measured every sky point at 255 and every foreground point at zero. Resolve these basenames to local disposable copies when constructing the manifest; no private absolute source paths are committed.

| RAW basename | Sky x/y | Foreground x/y |
| --- | --- | --- |
| `003_P1095908.RW2` | Expect no sky | Whole-image rejection |
| `010__1000868.RW2` | Left (.04, .08); right (.91, .08) | Shirt (.31, .74); canopy (.76, .035); face (.45, .31); grass (.85, .52) |
| `014__1002582.RW2` | Gap (.40, .12) | Trunk (.14, .30); foliage (.82, .49); path (.57, .85) |
| `022_P1095821.RW2` | No positive assertion | Dress (.46, .47); the bow (.46, .15) separately fails photographic quality |
| `052__1000872.RW2` | Expect no sky | Whole-image rejection |
| `099_P1000282.RW2` | Overcast (.20, .06) | Hat (.64, .23); denim (.47, .73); coat (.55, .53); log (.55, .90) |

Example fixture entry: `{"name":"Overcast/blue hat","path":"/absolute/path/to/copied.RW2","expectNoSky":false,"points":[{"name":"sky","x":0.20,"y":0.06,"minimum":151,"maximum":255},{"name":"hat","x":0.64,"y":0.23,"minimum":0,"maximum":49}]}`. Store entries as a JSON array and run `./scripts/test.sh --no-parallel --filter SkyQualityControlTests` with the three environment variables described above.

## Sampled results and limits

- Blue blanket and blue sweatshirt/building controls correctly return no sky.
- Visible left/right sky in the shirt photo, central sky in the woodland photo, and overcast sky in the hat photo retain strong coverage. Annotated shirt, canopy, dress, hat, denim, skin, trunk, foliage, path and log points remain below 50/255; this samples points rather than proving every foreground pixel is excluded.
- **FAIL — white bow:** the window portrait includes false sky on the white hair bow. At normalized (0.46, 0.15), the old and current initial masks both measure 222/255. Close-up inspection confirms foreground spill; this is a pre-existing semantic error, not introduced by blue branch recovery. Nearby bright defocused background is ambiguous and was not labeled as a definite no-sky control.
- **FAIL — complete fine-edge/sky coverage:** woodland masks still miss fine gaps and have soft edges. Previous shaded branch and group-selection limitations remain open.
- **NOT VERIFIED — reflections:** no clear water/glass reflection control with visible sky was identified in this staged collection. A window/building image with no detected sky is not equivalent to testing reflected sky alongside real sky.

Separate old/current artifact runs have both increased and decreased pixels: decreases greater than one byte affect 1,791 shirt-photo pixels, 2,421 woodland pixels, 4,507 window-portrait pixels, and zero overcast-photo pixels. These are differences between complete independent analysis runs with different context configurations, not a same-prediction causal measurement. The production recovery's `max(original, added)` still preserves its own baseline for the same prediction. Broad cross-run byte equality is not established, and changes at boundaries must be inspected. No segmentation correction is justified solely from these aggregate counts.

## Verification

| Gate | Result and evidence |
| --- | --- |
| Static/build | **PASS** — `git diff --check`, source review, focused and full debug app build; document links resolve |
| Unit/integration | **PASS** — focused `SkyQualityControlTests`: six RAWs / sixteen points, 63.372 seconds; `./scripts/qa.sh`: 306 reported in 65 suites, **300 executed / six skipped**, 231.823 seconds, including existing branch/group/workflow/native regressions |
| Sampled media/export | **PASS** — six initial source/mask/overlay/preview/export artifact inspections, raster persistence round trip, and six-original/six-copy inventory hashes; passing points do not establish whole-mask quality |
| Whole-mask quality | **FAIL** — white-bow foreground spill and incomplete fine gaps remain |
| Runtime/UI | **NOT VERIFIED** — no fresh UI run for this test/documentation change; production code unchanged |
| Performance/reflection/full shoot | **NOT VERIFIED** — no whole-app/matched-baseline/threshold measurement, actual reflected-sky control or genuine single-shoot acceptance |

Full QA skips broad Auto comparison, both mask-performance tests, isolated RAW memory profile, the sky crop experiment and the separate outdoor-sky sample. Source review is advisory, not a functional quality pass. Logs: `/private/tmp/perception-sky-expansion-controls.log`, `/private/tmp/perception-sky-expansion-artifacts.log`, `/private/tmp/perception-sky-expansion-baseline.log`, and `/private/tmp/perception-sky-expansion-full-qa.log`. GitHub final-head CI is recorded on draft PR #7; private fixtures are not available there. The automated gate covers tests/build/static checks; visual artifact inspection covers these six fixtures only. No fresh app UI, whole-app footprint, matched performance baseline or full-shoot acceptance was run because production behavior is unchanged. Observed initial analysis durations were 0.80–15.36 seconds across the six fixtures; they are single diagnostic observations with varying model/cache conditions, not timing targets or accepted ceilings.

Next: address confirmed bright-foreground semantic spill using a reproducible foreground/sky control that preserves genuine bright sky and fine gaps; add an actual reflection fixture before closing reflected-object acceptance. Keep the active [sky plan](../plans/active/sky-branch-recovery.md) and [Phase 3 roadmap](ROADMAP.md) open.
