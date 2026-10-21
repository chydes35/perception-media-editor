# Video stabilization prototype — 2026-10-20

Decision: **NO-GO for Milestone 2 production-engine selection at this point.** Native
translation is a promising provisional baseline. Keep the prototype isolated until
real scenario/visual acceptance and robust failure handling are established.
Milestones 2–6 are unstarted. The photo-first roadmap is unchanged.

The owner supplied the full engineering plan and authorized only M0/M1. Its complete
scope is carried in the [active ExecPlan](../../plans/active/video-stabilization.md).
Implementation and reproduction commands are in the [harness README](../../Tools/VideoStabilizationProbe/README.md).

## Scope and reproducibility

Repository baseline: `0d3283aa9063bb081ac39554a66221c5e87db53f`, initially clean;
working branch `codex/video-stabilization-poc`. Existing photo, proxy, 10-bit color
and other development branches/worktrees were preserved. Application sources,
package dependencies, UI and schema 10 are unchanged.

Measured host: Apple M1 MacBook Air (`MacBookAir10,1`), 8 GB, macOS 26.6.2. Swift
6.4 / CLT; default SDK 27.0, selected SDK 26.5 for these checks. The probe compiles
for macOS 15. A macOS 15/Swift 6.1 runtime check remains NOT VERIFIED.
FFmpeg 8.1.2 supplies diagnostic decode/encode and metadata inspection.

All camera inputs are local read-only sources. Generated fixtures, binaries, reports
and movies are under the repository's ignored `.build/` on the external SSD. Each
benchmark source is SHA-256 checked before/after; no camera footage is committed.

Corrected accepted measurements: `.build/video-stabilization-final/`.
Earlier exploratory runs: `.build/video-stabilization-run/`; these must not be
substituted for corrected results. Baseline, build and regression logs are in
`.build/video-stabilization-baseline/`.

### Important measurement qualifications

- `none` measures original decode/reduction. Native candidates and vid.stab then
  consume the same reduced diagnostic baseline. Candidate analysis timing is not
  original-camera decode-inclusive; native render includes its decode/encode.
- The vid.stab adapter phase timings exclude FFmpeg decode/encode. It is one-threaded,
  accuracy 15 / shakiness 5, Gaussian radius 12 frames, bilinear, automatic static zoom,
  no sharpening. The native smoother uses an actual-time local-linear fit, radius 0.5 s.
- Installed FFmpeg has no `vidstabdetect` or `vidstabtransform`. The local C adapter
  calls pinned vid.stab public APIs; this is a library/reference-pipeline comparison,
  not an execution of the absent FFmpeg filter wrappers. No global installation or
  production dependency was added. Pinned v1.1.1 revision:
  `90c76aca2cb06c3ff6f7476a7cd6851b39436656`; retain its GPL notices.
- Native crop is limited to 15% total dimension removed per axis by reducing correction
  strength. The external reference is not constrained to that budget. These are not
  equal-crop quality rankings.
- Residual jitter is RMS time-aware **x/y acceleration**, measured again on encoded
  output using Vision translation. Angular motion, parallax, moving-subject correctness
  and perceptual wobble are not captured. Reject/cut triplets are excluded. A separate
  summary uses identical valid triplets across methods to make coverage explicit.
- Reference raw frames are remuxed at 24 fps. Its fractional/VFR timing and native/audio
  synchronization are not validated. Native output PTS are checked rationally after
  encoding, not inferred from input frame counts or nominal FPS.
- These are single-run observations, without a controlled cold/warm, idle-app or
  thermal baseline. Physical footprint, RSS and sampled compressed memory are separate.
  System swap snapshots are not causally attributable to the probe.

## Baseline and verification

The initial `./scripts/qa.sh` hit sandbox EPERM in the Swift build service before tests.
Normal-access retry exposed a missing SDK 27 `SwiftUIMacros.StateMacro` plugin in CLT.
SDK 26.5 with the default build system then exposed missing `TestingMacros` discovery.
No application changes were made to work around these environment failures.

Successful baseline command:

```sh
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  ./scripts/test.sh --build-system native --no-parallel
```

Baseline: 382 reported tests / 82 suites, 351 passed and 31 skipped declarations,
354 executed parameterized invocations, 52.883 s; app build passed (0.80 s).
Skipped private-input tests do not establish new RAW or camera quality acceptance.

Standalone math checks first failed with unchanged jitter, then passed with actual
time-based smoothing. Checks cover identity, ≥30% alternating-jitter reduction, strength
zero/nonfinite safety, rejected observations, linear pans/endpoints with irregular PTS,
segment isolation, inverse-corner crop containment, radians/sign and rational clip mapping.

The focused Python suite tests actual FFmpeg irregular PTS, encoded native fractional
PTS, Darwin memory-log parsing, time-linear pan acceleration and rejected-triplet scoring.
Independent causal verification accompanies harness fixes; see closeout below.

## Camera fixtures and compatibility

Local inventory: nine original DC-S5 clips, all 3840×2160 at 24000/1001; seven H.264
10-bit 4:2:2 V-Log/V-Gamut and two H.264 8-bit Standard. Camera acquisition XML identifies
V-Log even when stream tags say BT.709. Six iPhone 15 Pro clips are 4K ProRes HQ 10-bit,
with landscape/−90°/−180° orientation and BT.2020 unspecified-transfer, HLG or BT.709.
HLG sample side data inspected here identifies ambient-viewing metadata, not Dolby Vision.
Do not label unspecified-transfer iPhone footage Apple Log without additional evidence.

Selected corrected runs and their hashes/results are recorded below after completion.
No available S5 recording is 60p. No confirmed iPhone HEVC/Dolby Vision fixture is in
this collection. The owner will identify/review interview, walking and deliberate-pan
scenarios later; camera/file naming alone cannot establish that coverage.

## Measurements

All figures below come from the corrected run and common valid frame-index triplets.
Negative improvement means measured jitter increased; it is not suppressed as a small signal.
The iPhone baseline signals (140.291/313.701/339.526 px/s²) are lower than the S5 signals,
but no calibrated noise floor or perceptual threshold permits dismissing their regressions.

| Fixture / requested excerpt | Baseline RMS px/s² | Common triplets | Translation reduction | Homography reduction | vid.stab reduction |
| --- | ---: | ---: | ---: | ---: | ---: |
| s5-event / 3 s | 4301.233 | 70 | 71.60% | 45.74% | 69.05% |
| s5-sports / 10 s | 1742.395 | 235 | 65.16% | 72.78% | 67.37% |
| iphone-landscape / 5 s | 140.291 | 118 | -60.36% | 0.00% | -60.36% |
| iphone-hlg / 5 s | 313.701 | 118 | -23.06% | 26.32% | -44.42% |
| iphone-sdr / 5 s | 339.526 | 118 | -10.43% | 43.69% | -33.43% |

S5 sports has 235 common triplets; baseline and other individual series have 238.
Reference results use 24-fps remux timing; they are approximate on fractional/VFR inputs.
Scene names describe sampled contents, not confirmed interview/walking/pan categories.

#### Follow-up: reduced translation strength on iPhone excerpts

The measured full-strength iPhone regressions prompted a bounded re-render sweep
using the development harness at strengths 0.25, 0.5, 0.75 and 1.0. Each candidate
was rendered from the same reduced diagnostic baseline, then decoded and remeasured
with Vision. All rows use the same 118 valid frame triplets and exact source PTS.
This measures encoded diagnostic output, not original-quality HDR/ProRes delivery.

| Excerpt | Strength | Output RMS px/s² | Change vs baseline | Dimension removed |
| --- | ---: | ---: | ---: | ---: |
| iPhone landscape | 0.25 | 205.365 | −46.39% | 0.21% |
| iPhone landscape | 0.50 | 212.100 | −51.19% | 0.41% |
| iPhone landscape | 0.75 | 237.135 | −69.03% | 0.62% |
| iPhone landscape | 1.00 | 224.966 | −60.36% | 0.83% |
| iPhone HLG | 0.25 | 355.703 | −13.39% | 0.29% |
| iPhone HLG | 0.50 | 414.139 | −32.02% | 0.57% |
| iPhone HLG | 0.75 | 410.731 | −30.93% | 0.86% |
| iPhone HLG | 1.00 | 386.029 | −23.06% | 1.15% |
| iPhone SDR | 0.25 | 304.606 | **+10.29%** | 0.35% |
| iPhone SDR | 0.50 | 322.539 | **+5.00%** | 0.70% |
| iPhone SDR | 0.75 | 378.675 | −11.53% | 1.04% |
| iPhone SDR | 1.00 | 374.944 | −10.43% | 1.39% |

Only the SDR excerpt improved at reduced strength, by 10.29% at 0.25 and 5.00%
at 0.50; those results are below the provisional 30% target. Landscape and HLG
regressed at every tested strength. Strength 1.00 reproduces the earlier result.
All values and per-run reports are in ignored local scratch at
`.build/video-stabilization-final/strength-sweep-retry/results.json`.

An independent path-space sweep predicts improvement at every positive strength
for all three iPhone excerpts, while encoded remeasurement does not. Source and
output samples have identical rational timestamps and frame counts, ruling out
index/PTS misalignment in this comparison. The model/output discrepancy is real;
its cause is unproven. These in-sample path predictions cannot override encoded
measurements or justify a correction-strength policy.

| Fixture | Translation crop | Homography crop | vid.stab zoom-induced crop |
| --- | ---: | ---: | ---: |
| s5-event | 13.52% | 11.06% | 24.76% |
| s5-sports | 6.98% | 8.26% | 5.31% |
| iphone-landscape | 0.83% | 0.81% | 3.26% |
| iphone-hlg | 1.15% | 1.39% | 3.36% |
| iphone-sdr | 1.39% | 1.48% | 5.23% |

The pinned reference maps output to source using `z = 1 - zoom/100`, so its reported
zoom percent represents total linear-dimension loss. Its unconstrained 24.76% event
crop exceeds the native 15% budget. Native maximum here is 13.5222%.

### Synthetic accuracy and controls

| Case | Native translation | Constrained homography | External reference |
| --- | --- | --- | --- |
| jitter | 96.92% residual reduction; delta RMSE 0.382 px | 95.65% reduction; delta RMSE 0.426 px | 100% translation-residual reduction |
| irregular-pts | 97.14% residual reduction; delta RMSE 0.382 px | 95.31% reduction; delta RMSE 0.425 px | NOT VERIFIED for VFR timing (retimed) |

On the known rotation fixture, constrained homography frame-delta error is 0.002445° RMSE and 0.0431 px center-displacement RMSE. Translation-only residual zero does not certify angular output quality.

Static geometry is identity in translation mode. Uniform and cut cases have no meaningful
baseline jitter-reduction percentage; validity/segmentation is checked instead. The pure
smoother preserves linear pans. From known synthetic motion plus commanded correction,
pan slopes remain 12.014 px/s (translation) and 12.002 px/s (homography), versus 12 px/s
input; this is commanded geometry, not an independent perceptual/encoded-pixel pan pass.

### Time and memory

Seconds below separate phases. Source first-pass decode/reduction excludes the second
baseline render/transcode pass, which is also shown. Native A/R means normalized-source
analysis and diagnostic render; reference A/W means library analysis and raw-frame warp
(FFmpeg conversion excluded). Storage/cache load and different encoders/intermediate
formats prevent interpreting these as matched end-to-end speed rankings.

| Fixture | Source decode pass | Baseline render pass | Translation A/R | Homography A/R | vid.stab A/W |
| --- | ---: | ---: | ---: | ---: | ---: |
| s5-event | 3.578 | 0.982 | 0.378/0.320 | 0.775/0.375 | 0.505/1.552 |
| s5-sports | 3.039 | 18.525 | 0.919/1.301 | 4.992/2.383 | 5.885/7.524 |
| iphone-landscape | 20.691 | 26.982 | 1.410/2.605 | 3.367/0.991 | 0.592/2.997 |
| iphone-hlg | 23.621 | 17.271 | 0.643/0.594 | 1.245/0.632 | 0.883/2.244 |
| iphone-sdr | 14.467 | 12.065 | 0.539/0.471 | 1.403/0.495 | 2.438/2.451 |

| Fixture | Original decode/render peak physical MiB | Translation peak physical MiB | Homography peak physical MiB | Reference CLI peak physical MiB |
| --- | ---: | ---: | ---: | ---: |
| s5-event | 75.06 | 37.52 | 32.91 | 6.17 |
| s5-sports | 70.75 | 46.00 | 37.16 | 8.78 |
| iphone-landscape | 63.08 | 31.86 | 31.64 | 7.14 |
| iphone-hlg | 59.92 | 41.91 | 42.89 | 7.41 |
| iphone-sdr | 59.66 | 41.99 | 40.33 | 7.67 |

Peaks are process physical footprint from Darwin `time -l`, not a whole-system/decoder-
daemon total or idle-app delta. RSS and sampled compressed values remain in motion JSON
and summary. The measured machine already had several GiB of system swap in use; snapshots
cannot establish that the probe caused or avoided swapping. The proposed app memory/UI
targets are NOT VERIFIED.

The separate longer-source experiment uses original `P1107172.MOV`: 4K H.264 8-bit
Standard/BT.709 at 24000/1001. It measures decode-only and decode-plus-translation in
separate processes, with no output encode. It does not substitute for long 10-bit/V-Log,
a confirmed documentary scenario, or app playback/thermal validation.

| Source excerpt | Frames | Decode-only s | Native decode + analysis s | Native peak physical MiB | Native peak RSS MiB | Sampled compressed MiB |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 15 s | 360 | 5.144 | 4.996 | 50.10 | 44.95 | 1.12 |
| 30 s | 720 | 9.531 | 10.131 | 49.28 | 43.72 | 4.42 |
| 60 s | 1439 | 20.590 | 20.862 | 50.74 | 42.48 | 5.28 |
| 90 s | 2158 | 32.440 | 28.823 | 51.63 | 42.27 | 4.86 |

The native profile peak is approximately 49–52 MiB over these durations; decoder/system
surfaces outside the process and whole-app residency remain separate. Warm caches and
run variability can make a later analysis pass faster than decode-only; subtracting these
single observations does not isolate the estimator's CPU cost. Sustained thermal and UI
acceptance remain NOT VERIFIED.

Long-source SHA-256 before: `0658989aad2d61842aee7a728fe0e86040641726e3ea886304269e3183a66840`; final after-check **PASS**, same hash.

### Color, orientation and source safety

Native output metadata is H.264/yuv420p, 8-bit BT.709: 960×540 landscape, 540×960
portrait, with orientation baked into pixels. Reference outputs have the same dimensions
and BT.709 matrix but omit primaries/transfer metadata in the inspected files.

The first static frame exposes a neutral round-trip difference with **exactly zero
translation corrections, zoom 1 and matching timestamps/dimensions**: native RGB mean
absolute error `[9.44446, 9.86748, 9.56456]/255` against its diagnostic baseline. Reference
error is `[2.56243, 3.92045, 2.79049]/255`. Homography is similar, with tiny nonzero geometry.
This includes decoder/conversion/encoding effects; it is not a calibrated original-camera
color metric. The cause is not established; conversion and metadata handling need a separate
controlled investigation. Neutral color fidelity is an additional production gate failure.

All 12 benchmark inputs have unchanged before/after hashes, including these five originals:

| Original | Case | SHA-256 before = after |
| --- | --- | --- |
| P1107158.MOV | s5-event | `6314642235444cad03935a2b204741b28ff58703280d5955a89be8c0e947b5e8` |
| P1107210.MOV | s5-sports | `1e476b42660ab4529009d9cd7dc1ddbbe8c4d8f760518872478381d36566340c` |
| IMG_0002.MOV | iphone-landscape | `05499aa118d605ec15f1a3959e2b4615e135add974969f00dd6ab41c65050557` |
| IMG_0005.MOV | iphone-hlg | `58b90695a4be5a7ae01001a05ead022e89d9466f8c31c4f08cb610dcb94338ce` |
| IMG_0006.MOV | iphone-sdr | `efebb5b201394542f399712b25d58bf2017edb97118dd716b5a587a0df8211a8` |

S5 inputs are original 4K 10-bit 4:2:2 V-Log; iPhone inputs are original ProRes HQ
10-bit, including portrait HLG and SDR. Successful diagnostic decode does not establish
original-quality output. All native rendered outputs passed exact rational encoded-PTS
checks, including unequal 1/20 / 1/30-second intervals.

The synthetic fixtures have known translation and rotation. Constant pan and static
controls prevent a smoothing score from rewarding simple frame freezing. Native
encoded PTS are checked on every accepted rendered output. Scene-cut and low-feature
cases explicitly probe unreliable observations rather than merely generating a movie.

## Observed limitations and recommendation

Independently confirmed limitations from the prototype and its artifacts:

- Translation resets at the mirrored synthetic cut. Constrained homography accepts
  the discontinuity without resetting its path and can introduce false rotation.
- Uniform low-feature input gets confidence 1 from both requests. Translation rejects
  119/120 observations through other validation; homography accepts zero-motion results.
  Confidence alone is not an adequate reliability policy.
- Native translation increases the measured residual on all three iPhone excerpts;
  constrained homography improves two and leaves landscape effectively unchanged.
  Lower baseline signal does not establish that the regressions are imperceptible.
- Homography rendering is rigid-only, but that does not establish robust rigid path
  estimation in real scenes. Cumulative small-motion addition is a prototype approximation.
- Real interview/walking/pan labels and full side-by-side human playback acceptance
  are missing. A low residual score alone can favor subject-locked or distorted footage.
- All outputs are **8-bit SDR diagnostic** movies after BGRA/sRGB conversion. Original
  10-bit 4:2:2, V-Log, HDR and Dolby Vision preservation remain NOT VERIFIED, with an
  intentional diagnostic format downgrade. No production support is implied.
- Even the neutral static diagnostic round trip differs by about 9–10 RGB code values
  per channel in translation mode, despite identity geometry. The cause needs separate
  investigation; no color-neutral or original-quality rendering pass is claimed.
- No audio is rendered. Whole-app interaction latency, AVPlayer drops, preview/export
  correspondence, project replacement and production cancellation ownership are untested.
- The real FFmpeg filter wrapper, equal-crop estimator comparison, 60p, confirmed
  Dolby Vision/HEVC and sustained target-app thermal behavior remain unverified.

Recommendation: retain native translation as the provisional research baseline;
evaluate a robust rotation/feature estimator (including OpenCV if native observation
validation remains inadequate) before choosing a production engine. First establish
reliable cuts and low-feature behavior, review the labeled real scenarios and output
motion, and validate the intended full-resolution/color path. Do not start M2 service,
cache or integration implementation as part of this change.

The next product roadmap work remains the existing photo quality/reliability gates.
The next stabilization action is the owner's scene/quality review plus a bounded
estimator-validation follow-up, not production integration.

## Corrections and independent review

- Memory parsing: Darwin reports `peak memory footprint`; the initial parser only
  recognized `maximum memory footprint`. Reproduced, fixed, independently reverted
  to red and restored to green. Earlier raw logs remain valid; parser omissions do
  not become invented zero memory values.
- Irregular fixture: an initial coarse FFmpeg timebase rounded offsets back to CFR.
  Explicit `settb=1/24000` fixes the generator; actual encoded unequal PTS regression
  went red→green and was independently causally verified. The old `irregular` row is excluded.
- Native encoder: the default writer chose timescale 600, rounding S5 source PTS by
  up to 0.833333 ms. The input now explicitly uses the source timescale and rejects
  unsupported inconsistent timebases. An actual encoded-PTS regression went red→green;
  earlier real timing-dependent results are excluded from final tables.

Independent reviewers confirmed baseline counts, repository/format/filter facts,
bounded frame retention, crop geometry, output-directory refusal and vid.stab API use.
Final corrected metrics, common-triplet coverage, encoded timestamps and long-profile tables were independently checked against motion reports and time logs. All three harness fixes have independent causal baseline/red → fixed/green → temporary-revert/red → restored/green evidence. The final encoder verification full focused suite passed 5/5; source/binary copies restored exactly.

Rejected: both native modes miss the cut — translation resets correctly.

Rejected: both modes accept uniform footage — translation rejects 119 observations.

Rejected: zero translation residual proves rotation quality — angular residual is omitted.

Rejected: old irregular fixtures prove VFR support — their encoded timestamps were CFR.

Rejected: appending exact PTS proves encoded timing — writer timescale must also be verified.

Rejected: current FFmpeg supports vid.stab filters — both filters are absent.

Rejected: diagnostic results establish HDR/10-bit or visual acceptance — neither gate is closed.

## Final gates

| Gate | Result | Evidence / limitation |
| --- | --- | --- |
| Baseline app tests/build | PASS with environment workaround | Native SwiftPM / SDK 26.5; counts above |
| Current diff/source review/app checks | PASS | Diff/link checks; deterministic source reviewer; final serial app tests/build with SDK 26.5/native workaround |
| Standalone math/focused regression | PASS | Standalone math; five current Python tests; independent causal fix verification; four-point rendered iPhone strength sweep |
| Native synthetic translation feasibility | PASS | Corrected CFR/unequal-PTS residual reduction exceeds provisional 30% target; not perceptual acceptance |
| Robust cut/reliability policy | FAIL | Homography misses known cut; ambiguous confidence |
| Measured iPhone motion improvement | FAIL | Full-strength translation increases residual in all three; only low-strength SDR improves, by 10.29%, while landscape/HLG regress across all four strengths |
| Neutral diagnostic color | FAIL | Identity-geometry first-frame RGB difference about 9–10/255; cause unproven |
| CLI performance measurements | PASS | 15/30/60/90 s original-source runs and native/reference phase/memory tables above |
| Real camera diagnostic decode/render | PASS | Two S5 / three iPhone excerpts; exact native encoded PTS; explicit SDR diagnostic downgrade |
| Selected original hash checks | PASS | Seven synthetic and six original source hashes unchanged, including long source |
| Original-quality log/10-bit/HDR delivery | NOT VERIFIED | Diagnostic downgrade; production out of scope |
| Scenario/human motion quality | NOT VERIFIED | Owner will review later |
| Target-app UI/audio/memory/thermal gates | NOT VERIFIED | CLI evidence cannot close them |
| Production engine decision | NO-GO | Open acceptance above; M2–M6 unstarted |

Final current application check: **382 reported tests / 82 suites**, **351 passed /
31 skipped declarations**, 47.458 seconds; app build completed in 0.62 seconds.
The three parameterized passing declarations still expand to 354 executed invocations.
This is the SDK 26.5/native-build workaround above, not a claim that unmodified
`./scripts/qa.sh` passes on the incomplete default SDK 27 toolchain.

## Local comparison artifacts

[Four-pane S5 comparison movie](../../.build/video-stabilization-final/s5-event/comparison.mp4)
and [sampled still at 1.5 seconds](../../.build/video-stabilization-final/s5-event/comparison.jpg).
These private local derivatives are not committed. The sampled still was inspected
for framing and tone differences; full playback/wobble/face-distortion acceptance
by the photographer is **NOT VERIFIED**. The reference pane runs at 24 fps and is
not used to prove native timing. Reproduce after the reference benchmark with:

```sh
python3 Tools/VideoStabilizationProbe/run.py comparison \
  .build/video-stabilization-final --case s5-event
```
