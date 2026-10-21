# Video stabilization research harness

Development-only Milestones 0/1 experiment. These files are deliberately outside
the Swift package and do not change the editor, project schema, playback or export.
See [the ExecPlan](../../plans/active/video-stabilization.md).

`Motion.swift` contains time-based local-linear smoothing, rigid geometry and crop
math. `MotionChecks.swift` runs independent math checks without SwiftUI.
`Probe.swift` streams actual source PTS through AVFoundation, reduces frames to at
most 960 px, uses Vision translation or constrained homography, smooths motion and
writes a diagnostic video with matching source timestamps. Analysis and rendering
are separate passes. Homography contributes only center displacement and rotation;
perspective is never applied. The additive small-motion path is experimental.

The decode uses full-resolution BGRA before reducing it. Only adjacent reduced frames
are retained by the analysis loop; decoder/system allocations are additional. Results
retain compact timestamp/motion arrays. The CLI limits each run to 180 seconds.

## Build and check

```sh
# On the measured CLT installation, SDK 27 cannot build the SwiftUI app; SDK 26.5 can.
PME_PROBE_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  zsh Tools/VideoStabilizationProbe/build.sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s Tools/VideoStabilizationProbe -p test_metrics.py
```

The standalone probe does not require Swift Testing or the app's SwiftUI macro plugins.
On other machines omit `PME_PROBE_SDK` to use `xcrun`'s SDK. macOS 15 is the compile
deployment target; this does not claim a run on macOS 15 or Swift 6.1.

```sh
# Parent must exist, output directory must NOT exist. Example uses local private media.
.build/video-stabilization-baseline/probe \
  /Volumes/ExSSD1/Pictures/110_PANA/P1107158.MOV \
  .build/my-new-stabilization-result translation 0 3 960 render
```

Arguments: source, new output directory, `none|translation|homography`, start seconds,
duration seconds, long edge, `render|analyze`. `none` measures decode/conversion alone.
Translation strength defaults to 1. For a controlled diagnostic sweep, set
`PME_STABILIZATION_STRENGTH` to a finite value from 0 through 1. The report records
requested strength separately from any additional reduction required by the crop limit.
The JSON contains source CMTime values/timescales, segments, confidence, validity,
camera path, corrections, crop and timings. `motion.json` is written after successful
rendering. Failed/killed experiments can leave incomplete diagnostic files in their
new scratch directory; absence of a complete JSON marks an unfinished run.

Output contains no audio and uses H.264 8-bit SDR BT.709 after BGRA/sRGB conversion.
It is a framing/motion experiment, **not** log/HDR/Dolby Vision/10-bit delivery support.
It cannot establish audio synchronization, preview/export correspondence or integrated
app responsiveness. No UI results or integration are published by this executable.

## Synthetic and real benchmarks

Python 3, Pillow, `ffmpeg` and `ffprobe` must already be available. Synthetic data uses
a seeded texture with known zero motion, deliberate pan, jitter, rotation, unequal PTS,
low-feature input and a cut. The regression suite inspects actual encoded unequal PTS.

```sh
python3 Tools/VideoStabilizationProbe/run.py prepare .build/my-new-fixtures
python3 Tools/VideoStabilizationProbe/run.py benchmark .build/my-new-fixtures
PYTHONDONTWRITEBYTECODE=1 python3 Tools/VideoStabilizationProbe/summarize.py .build/my-new-fixtures
```

Real manifest: JSON array of `{"name":"unique-case", "path":"/absolute/source.mov",
"duration":5}`. Place it in local scratch, then supply `--manifest /path/to/manifest.json`.
Each case must have a new name/output directory. The runner reads and SHA-256 checks
each source before/after. Never put private recordings or generated videos in Git.

Each method runs sequentially in a separate process. Native candidate analysis uses
the same reduced diagnostic baseline as the external reference. Original decode/
conversion time is recorded separately. Reanalysis of encoded output measures RMS
time-aware x/y acceleration (pixels/s²), excluding invalid/cut triplets. This is only
global translation jitter; it does not prove rotational, subject-motion or visual quality.
Synthetic estimation errors separately compare frame deltas against ground truth.
Crop is total dimension removed per axis (`1 - 1/zoom`), not per-side crop.

`/usr/bin/time -l` captures whole-process peak physical footprint/RSS; native JSON
also samples physical footprint/compressed memory during analysis. These are distinct
measurements. Swap/thermal snapshots are system-wide observations, not causal app data.

`summarize.py` reports common valid triplets and post-encoder format metadata. Its
static first-frame RGB difference measures diagnostic round-trip error, including
compression; it cannot establish original log/HDR color fidelity.

For the separate 15/30/60/90-second original-source profile, with no concurrent heavy job:

```sh
python3 Tools/VideoStabilizationProbe/run.py performance .build/my-new-fixtures \
  --source /absolute/path/to/a-video-at-least-90-seconds.mov
```

This records decode-only and decode-plus-native-translation jobs in fresh processes
and checks the source hash across the whole sequence. It does not render output,
profile the editor, or establish the proposed idle-app memory delta.

## Optional external vid.stab reference

The measured Homebrew FFmpeg 8.1.2 lacks `vidstabdetect`/`vidstabtransform`. Instead,
`VidstabReference.c` calls vid.stab's public detection, motion fitting, Gaussian
smoothing and transform APIs, with FFmpeg supplying/encoding diagnostic YUV420 frames.
This tests the library through a local adapter, **not the absent FFmpeg filter wrapper**.
No sharpening is added; accuracy 15, shakiness 5, one thread, smoothing radius 12 frames,
bilinear interpolation and automatic static zoom. The reference is not crop-limited.

```sh
git clone --depth 1 --branch v1.1.1 https://github.com/georgmartius/vid.stab.git \
  .build/video-stabilization-baseline/vidstab-source
PME_PROBE_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
PME_VIDSTAB_SOURCE="$PWD/.build/video-stabilization-baseline/vidstab-source" \
  zsh Tools/VideoStabilizationProbe/build.sh
python3 Tools/VideoStabilizationProbe/run.py benchmark .build/my-new-fixtures --reference
python3 Tools/VideoStabilizationProbe/run.py comparison .build/my-new-fixtures --case jitter
```

Pinned source: tag v1.1.1, revision `90c76aca2cb06c3ff6f7476a7cd6851b39436656`.
The pinned headers carry GPL notices; retain the upstream source/license locally.
The C adapter is separate from the app and uses 8-bit planes, so it cannot establish
10-bit 4:2:2 or HDR support. Reference timings exclude FFmpeg decode/encode; native
analysis includes normalized-source decode and native render includes its decoder/encoder.
Do not compare those phase timings as identical pipelines.

Reference raw output is remuxed at 24 fps. For actual unequal PTS/VFR and 23.976 fps
inputs, treat its timing/acceleration comparison as a limitation, not frame-timing proof.
If using a separate FFmpeg build with the real filters, record its version/license,
use identical frame order in both passes and keep that build outside production dependencies.

The Milestone 1 evidence report records known failures and the decision gate. A good
jitter number cannot close human quality acceptance, reliable cuts, real scenario
coverage, full-resolution color, audio or whole-app performance.
