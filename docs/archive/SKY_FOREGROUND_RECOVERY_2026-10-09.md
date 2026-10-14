# Bright foreground excluded from sky — October 9, 2026

Start: `4d2b696`, clean photo workflow integration checkout. Phase 3 remains active. This correction changes new sky analyses; existing saved raster masks and schema 10 remain unchanged. Original media are read-only, using the previous disposable S5 RAW copies and pinned local model.

## Reproduction and decision

The window portrait `022_P1095821.RW2` selects its white hair bow as sky: normalized top-left (.46, .15) measures 222/255 and (.54, .12) measures 139/255. Adding both foreground assertions to the six-RAW controls fails twice before the correction.

Bounded native probes show accurate person segmentation at 249/184 and person-instance segmentation at 185/235 for those two points; neither gives strong confidence at both. General foreground instance masks measure 255 at both. Rather than subtract all general foreground (which could include trees), the correction selects only foreground instances with at least 16 label pixels and at least 60% area overlap with the sky model's semantic person class. This corroborates a person's identity before using the independent native model's finer coverage.

`SkyForegroundExclusion` runs one native foreground request only when the existing semantic prediction contains sufficient person pixels. Selected instances are combined into one scaled soft mask on the existing oriented source; no per-person crop loop or new model download is added. Confidence through 230/255 leaves sky unchanged; 231–255 smoothly removes high-confidence foreground. Tree-gap recovery runs first. Auxiliary request errors/empty results retain usable sky; cancellation is checked before/after inference and during pixel scans. A scoped autorelease pool releases temporary native resources before returning to the sky actor. Raster work stays bounded to 1536 pixels, with small native label buffers and no new application-owned retained cache. Native inference working memory is measured separately from these array bounds.

## Evidence and limits

The corrected two bow points measure zero. The existing four genuine-sky points remain 255, twelve foreground points remain zero, and the two no-sky outdoor controls remain rejected. Focused six-control execution passes 18 points in 114.089 seconds including three portable tests. The subsequent fixed RAW/persistence/fallback/cancellation suite passes five tests in 17.264 seconds. Invalid auxiliary input retains the offered sky, and canceled work throws rather than publishing a mask.

The correction does not identify reflected sky, recover all shaded/fine gaps, or solve remaining subject/group spill. Bright defocused background beside the portrait remains ambiguous; it is not asserted to be foreground or definite sky. Broad photographic acceptance stays open. Existing saved masks are not reanalyzed automatically.

## Verification

| Gate | Result and scope |
| --- | --- |
| Static/build | **PASS** — diff/source checks, focused/full debug builds, release build (45.73 seconds), ad-hoc deep signature verification and plist lint |
| Unit/integration | **PASS** — `./scripts/qa.sh`: 312 reported in 67 suites, **306 executed / six skipped**, 421.374 seconds, with 18-point controls and the 14-case selection runner (nine mask/export results, five expected no-sky outcomes); disabling the analyzer correction fails the exact RAW bow repro twice (222/139), and restored full QA passes |
| Sampled media | **PASS** — inspected bow, blue-shirt/canopy, woodland and overcast production preview/export artifacts; four genuine-sky points stay 255, fourteen foreground points stay zero; eleven originals and eleven copies match SHA-256 inventory |
| Release selection/persistence/export | **PASS** — isolated candidate generates Sky 1; saved PNG equals the focused-test reference byte-for-byte, both bow points zero; metadata survives reopening unchanged; full-resolution JPEG fully decodes at 4000 × 6000, matching source metadata |
| Initial edited preview after reopening | **FAIL** — after Export → New → Open same project → Photo → select Sky 1, edited canvas remains black. Original view displays the RAW; toggling overlay off/on refreshes the edited image and restores correct overlay. Root cause and pre-change reproducibility are NOT VERIFIED; do not attribute this to segmentation without causal evidence |
| Broad quality/performance/release acceptance | **NOT VERIFIED** — actual reflected sky, varied bright foreground, complete fine edges, matched performance/accepted thresholds, genuine single shoot and distribution signing |

The initial blank-canvas failure is recorded separately from successful persisted-raster recovery. Do not count the recovered view as a clean initial-reopen UI pass. The installed app was not replaced. Existing UI cancellation invalidates request identity; in-progress native work may finish, while directly canceled analysis tasks propagate cancellation at the checked boundaries.

M1/8 GB physical-footprint observations: lifetime peak **1,203,539,584 bytes (1.121 GiB)**; after export **334.1 MiB**; after project replacement **250.4 MiB**. The final lifetime peak is unchanged after reopening/refresh. No matched baseline or ceiling pass is claimed. Artifacts and sampler output stay under `.build/sky-foreground-recovery/`. Logs: `/private/tmp/perception-sky-foreground-{red,green,fixed-green,causal-red,full-qa,release}.log`. Full QA skips broad Auto comparison, both mask-performance tests, isolated RAW memory profiling, sky crop experiment and the separate outdoor-sky fixture. Final-head CI evidence is recorded on draft PR #7; it lacks the private RAW inputs. Initial corrected six-control analyses range 1.69–29.89 seconds, including RAW decode, semantic model and conditional foreground work. Conditions are not a matched timing experiment, so these observations do not establish a speed regression or accepted ceiling. The extra native request adds work on eligible photos; whole-app performance/full-shoot acceptance remains a separate gate.

Next: reproduce and fix the initial blank edited preview after reopening, then improve remaining fine-edge/shaded-sky coverage, add actual reflected-sky controls, and continue group coverage/real single-shoot acceptance under the [roadmap](../ROADMAP.md) and [active sky plan](../../plans/active/sky-branch-recovery.md).
