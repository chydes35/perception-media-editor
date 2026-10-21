# Video stabilization

Status: active; Milestones 0 and 1 only authorized for this change  
Roadmap item: [V0.3 video baseline](../../docs/ROADMAP.md#v03--video-editor-existing-baseline-development-deferred)  
Owner: Codex, lead macOS media-processing engineer  
Source: the full **Perception Media Editor — Video Stabilization Engineering Implementation Plan** supplied by the owner on 2026-10-20. This ExecPlan carries its complete scope forward; it does not authorize milestones 2–6.  
Branch: `codex/video-stabilization-poc`, from `0d3283aa9063bb081ac39554a66221c5e87db53f`.

## User outcome and acceptance

Produce naturally smooth, non-destructive video for documentary/interview footage,
walking B-roll and deliberate pans/tilts. Primary input is original Panasonic DC-S5
MOV/MP4, especially 4K 10-bit V-Log; secondary input is iPhone SDR/HDR, portrait
and variable frame timing. Target: macOS 15+, Swift 6.1+, M1 MacBook Air / 8 GB.
Use AVFoundation, Vision, Core Image and Swift concurrency without gyro metadata.

This assignment ends at a measured prototype and a go/no-go recommendation for
Milestone 2. It does not ship controls, migrate projects or integrate playback/export.
Video product work remains subject to the photo-first roadmap. The owner has
explicitly authorized this isolated research exception, not a roadmap rewrite.

First-release exclusions: optical-flow frame synthesis, rolling-shutter correction,
AI reconstruction, external gyro synchronization, subject-aware reframing and multicam.

Acceptance for the current scope:

- [x] M0: run baseline tests, document failures and integration boundaries, preserve behavior/schema, publish this reproducible protocol.
- [ ] M1: timestamped native decode → reduced analysis → Vision motion → camera path → smoothing → correction → comparison video on real footage.
- [ ] Evaluate translation first and constrained rotation from homography; never apply arbitrary perspective by default.
- [ ] Compare native results with external FFmpeg/vid.stab where available; do not link it to the app. Identify missing filters and reference limitations explicitly.
- [ ] Measure estimation error, residual jitter, pan preservation, rejection count, crop, duration, peak memory, codec support, color differences and visible artifacts.
- [ ] Exercise known translation/rotation plus S5 interview, walking and pan, and iPhone handheld/walking. Missing scenario labels remain NOT VERIFIED even if the camera codec is tested.
- [ ] Target ≥30% unwanted-jitter reduction on suitable synthetic fixtures; aim for ≤15% total dimension removed per axis. Metrics alone never close human documentary/interview/walking visual acceptance.
- [ ] Record measured decision and remaining gates before any M2 production work.

## Current state and affected contracts

Read: repository `AGENTS.md`, `.agent/PLANS.md`, task/milestone templates,
`docs/ARCHITECTURE.md`, `ROADMAP.md`, `CURRENT_STATUS.md`, `DATA_MODEL.md`,
`CODING_STANDARDS.md`, `TESTING_STRATEGY.md`, `PERFORMANCE_TARGETS.md`.
Initial worktree was clean on `main`; remote matches the requested repository.

Verified code boundaries:

- `VideoMediaService.swift`: main-actor metadata/poster service; metadata currently
  reports duration and orientation-adjusted dimensions, not full codec/color/timing.
- `TimelineCompositionService.swift`: main-actor composition assembly, one primary
  video/audio track; color processing only activates for non-neutral clip color.
  First playable clip supplies the composition track's preferred transform, so
  mixed per-clip orientation remains a documented limitation.
- Composition uses source/placement seconds converted to `CMTime` at timescale 600.
  Future stabilization must use actual source PTS and rational arithmetic:
  `sourceTime = sourceStart + (timelineTime - timelineStart)`; FPS×time is insufficient.
- The Core Image composition callback is sendable. The local SDK deprecates the
  existing async factory at macOS 27 in favor of `init(applyingFiltersTo:applier:)`.
  Keep the macOS 15 path until a separately tested availability migration is justified.
- `EditorStore.swift` owns trim/split/removal and composition rebuilding; splits
  currently copy color/audio metadata. Future stabilization belongs in a focused extension.
- `EditorModels.swift` / `ProjectDocument.swift`: schema 10, clip timing and separate
  clip color/audio dictionaries; atomic JSON saves reject future schemas.
- `ExportWorkspace.swift` / `EditorStore+Export.swift` export photos only. A native
  video delivery service still needs implementation in M5; prototype output is not that service.

Current-scope files: `Tools/VideoStabilizationProbe/` (standalone Swift harness,
pure math checks, fixture/benchmark driver), this plan, evidence report and status.
No modifications to application `Sources/`, `Tests/`, `Package.swift` or schema are required.
Original camera fixtures and generated media stay local, outside tracked files.

Future proposed file boundaries from the source plan (not created in M0/M1):

| File | Future responsibility |
| --- | --- |
| `Package.swift` | Review native framework/build requirements; no current dependency additions |
| `VideoMediaService.swift` | Full format/timing/color metadata inspection |
| `TimelineCompositionService.swift` | Shared per-clip geometry, orientation and color rendering |
| `VideoWorkspace.swift` | Stabilization inspector and Before/After |
| `EditorModels.swift`, `ProjectDocument.swift` | Separate clip settings and tested schema migration |
| `EditorStore.swift`, `EditorStore+VideoStabilization.swift` | Clip lifecycle, bounded state and operation ownership |
| `VideoStabilizationService.swift` | Motion estimation, segments and smoothing |
| `StabilizationMotionModels.swift` | Pure timestamped motion/correction/crop values |
| `StabilizationCache.swift` | Source-keyed disposable motion cache |
| `StabilizationRenderer.swift` | Per-frame geometry and cropping shared by preview/export |
| `VideoExportService.swift` | Validated delivery, progress/cancel and atomic publication |
| `VideoStabilizationTests.swift` | Algorithms, invalid motion, timing, crop and scene controls |
| `StabilizationIntegrationTests.swift` | Clip/project/cache/preview/export boundaries |
| `StabilizationPerformanceTests.swift` | Repeatable target-hardware diagnostics |

## Implementation steps

### Milestone 0 — Baseline and feasibility audit

- [x] Inspect git status, remote, revision, active branches and the required guidance.
- [x] Inspect import, composition, timeline editing, persistence and export code.
- [x] Create the initial implementation branch without disturbing other work.
- [x] Record toolchain: Swift 6.4; default macOS SDK 27.0; installed SDK 26.5 is also available; host macOS 26.6.2, Apple M1 / 8 GB.
- [x] Identify two baseline environment failures before source edits: sandbox EPERM
  writing XCBuild manifest, then normal-access SDK 27 build fails because CLT lacks
  `SwiftUIMacros.StateMacro`. Preserve both logs; do not alter app code to hide these.
- [x] Establish baseline with installed SDK 26.5 and SwiftPM native build system:
  382 reported tests / 82 suites, 351 passed and 31 skipped declarations (354 executed
  parameterized invocations), 52.883 s; app product build passed in 0.80 s.
- [x] Document orientation, timing, export and concurrency boundaries above.
- [x] Inventory local camera files using `ffprobe`; identify acquisition metadata
  independently of stream color tags. S5 V-Log metadata contradicts generic BT.709 tags.
- [x] Define the proof-of-concept test protocol below and synthetic ground truth.
- [x] Record isolated video decode/conversion baseline with the same harness/workload
  as the candidate (corrected S5 event: 3.5777 s first decode/reduction pass / 72 frames,
  plus 0.982 s baseline render). Existing app playback/frame-drop
  performance remains NOT VERIFIED; this is not an AVPlayer or whole-app measurement.

### Milestone 1 — Stabilization proof of concept

- [x] Add an isolated command-line harness compiled separately from the SwiftUI app.
- [x] Write/run deterministic math tests before implementing smoothing/crop/time helpers.
- [x] Decode actual `CMSampleBuffer` presentation timestamps, normalize track orientation,
  retain only adjacent reduced-resolution analysis frames (long edge ≤960).
- [x] Analyze translation with Vision; separately evaluate homography projected to a
  constrained rigid transform and reject unreliable/nonfinite/extreme observations.
- [x] Build path segments across rejected observations; smooth using time,
  preserving linear pans; derive correction independently from motion estimation.
  Reliable discontinuity detection remains open: homography misses the known cut.
- [x] Render baseline and corrected diagnostic movies with a shared diagnostic pipeline,
  at exact encoded source PTS, into new output directories. Neutral RGB drift was
  measured; original-quality color preservation is not established.
- [x] Generate synthetic static, pan, jitter, rotation and irregular-timing cases with
  known transforms. Quantify motion error separately from path smoothness.
- [x] Run local S5 and iPhone clips. Label scene contents from sampled frames; do not
  infer interview/walking/pan coverage from names or camera metadata.
- [x] Run external reference on the same diagnostic baseline; log exact FFmpeg
  version/filter settings. `deshake` is not an equivalent substitute for vid.stab.
  Used pinned vid.stab library APIs via a C adapter because installed FFmpeg lacks
  its filter wrappers. Reference raw remux is 24 fps, not a VFR timing validation.
- [x] Measure crop, actual decoded-output translation jitter, rejects, analysis/render
  time, physical footprint/RSS and color differences against the unstabilized baseline.
- [x] Inspect the generated four-pane S5 comparison still (1.5 s), record crop/tone
  differences and provide the local comparison movie. Full temporal/human visual
  acceptance remains NOT VERIFIED; the owner will review scenarios later.
- [x] Independently check findings and record **NO-GO** before M2. Translation regresses
  on all three tested iPhone excerpts; homography misses a cut; neutral diagnostic
  round trips change RGB values. Human/labeled scenario and production color gates remain open.

### Milestone 2 — Core engine (NOT STARTED; separate change)

- [ ] Create `VideoStabilizationService.swift`: bounded streamed analysis, progress,
  cancellation, confidence, scene cuts, trajectories, correction and crop requirements.
- [ ] Create `StabilizationMotionModels.swift`: timestamped motion/validity, boundaries,
  path segments, transforms, crop, config and algorithm version; UI-independent values.
- [ ] Create `StabilizationCache.swift`: disposable source-level motion data keyed by
  source identity/modification metadata, track, settings and version; atomic writes,
  corruption recovery, relink invalidation, cancellation and no embedded frame sequences.
- [ ] Reuse source motion for trims/splits; recompute clip smoothing/settings without
  re-decoding on strength changes. Deterministically interpolate arbitrary source times.
- [ ] Prove cancel, original protection, cache reuse/recovery, strength-only reuse,
  cut safety and UI independence before calling the engine complete.

### Milestone 3 — Timeline geometry/rendering (NOT STARTED; separate change)

- [ ] Extend composition with per-clip time-indexed corrections, including neutral color.
- [ ] Order: decode → normalize orientation/pixel geometry → stabilize → crop/fit/zoom
  → shared color in appropriate spaces → target canvas; avoid duplicate resize/conversion.
- [ ] Resolve first-clip orientation for mixed S5 landscape/iPhone portrait timelines.
- [ ] Evaluate the newer composition API availability separately; document a custom
  `AVVideoCompositing` need if the built-in path cannot meet geometry/quality requirements.
- [ ] Prove seeking, independent clips/settings, color coexistence, supported auto-crop
  without black edges, unchanged audio timing and visible safe fallback on missing data.

### Milestone 4 — Project/UI (NOT STARTED; separate change)

- [ ] Separate `VideoStabilizationSettings` from `PhotoAdjustments`: enabled, mode,
  strength, cropMode, maximumCropFraction, analysisVersion. Modes Gentle/Standard/Strong/Locked;
  crop Automatic/Manual limit. Persist `[UUID: VideoStabilizationSettings]` by clip.
- [ ] Persist settings only, not motion arrays. Verify schema at implementation time;
  if needed advance 10→11 with disabled defaults, old loads, round trips, future rejection.
- [ ] Add STABILIZATION inspector: toggle, Analyze/progress/cancel, mode, strength,
  crop behavior/percentage/warning, reset and Before/After.
- [ ] Use `EditorStore+VideoStabilization.swift`, bounded published state, coalesced
  slider changes, clip/project operation identities and safe stale-result rejection.
- [ ] Test split inheritance, deletion cleanup, replacement/cancellation, reopen and photo regressions.

### Milestone 5 — Delivery (NOT STARTED; separate change)

- [ ] Implement minimum `VideoExportService.swift`, shared correction data with preview,
  practical 1080p first; 4K only after codec/memory validation.
- [ ] Preserve source, duration/audio sync, orientation/dimensions, supported bit depth,
  primaries/transfer/metadata; explicitly reject unsafe log/HDR combinations.
- [ ] Validate V-Log separately from iPhone Dolby Vision. HEVC preset availability is
  not proof of HDR preservation. Compare representative decoded pixels and metadata.
- [ ] Progress/cancel, protected originals, temporary destination, atomic publication;
  failure/cancel must leave no completed-looking partial file.
- [ ] Verify preview/output geometry at identical source PTS, dimension/framing,
  hashes, audio sync, SDR support and explicit 10-bit/HDR results.

### Milestone 6 — Production validation (NOT STARTED; separate change)

- [ ] Run full camera/scenario matrix and whole-app M1/8 GB performance gates.
- [ ] Profile analysis/render bottlenecks, VideoToolbox, CI allocations, cache/disk,
  seek latency, dropped frames, sustained thermals and HDR/10-bit conversion costs.
- [ ] Optimize measured bottlenecks only. Document unsupported modes and require
  real human quality acceptance plus automated project/photo regression gates.

## Safety and performance

Originals are opened read-only; no transcodes beside originals and no modifications
to `.pmedit`. Use fresh exclusive output directories; reject existing destinations,
including symlinks. Hash selected originals before/after experiments. Never commit
camera recordings. The prototype's 8-bit SDR diagnostic outputs are geometry
experiments, not original-quality, HDR, Dolby Vision, V-Log or 10-bit delivery support.

One heavy job at a time. Start at 960 px long edge, two adjacent reduced frames;
decoder-managed full-resolution surfaces are separate and must be measured. Keep
timestamp/motion arrays, not decoded video. Cooperatively check cancellation between
decode/analysis/render steps; production stale-result ownership remains M2/M4 work.

Proposed targets, not passes: ≤512 MiB extra peak physical footprint over measured
idle app, roughly ≤3 GiB total app footprint, 100 ms p95 ordinary controls, no significant
swap growth; compact disk cache and adaptive preview/proxies if needed. Record physical
footprint, compressed memory, swap, elapsed time, frame drops and thermal behavior.
Benchmark 15/30/60 s plus a longer documentary clip. A CLI footprint does not establish
idle-app delta, UI responsiveness, whole-app peak or sustained thermal acceptance.

## Verification

### Reproducible proof-of-concept protocol

1. Record HEAD, clean/dirty state, host/SDK/compiler and source metadata. Preserve
   baseline `./scripts/qa.sh` logs. Pin SDK if the installed default cannot build.
2. Generate seeded textured synthetic sources with known zero, linear pan, alternating
   translation, rotation and irregular PTS; keep ground truth separately. Math tests
   cover identity, strength zero, jitter reduction, pan preservation, signs/units,
   failure/nonfinite safety, segment reset, crop containment and rational time mapping.
3. For each selected real clip, record camera/codec/format, actual PTS, duration,
   orientation, acquisition color, scenario and SHA-256. Include S5 10-bit 4:2:2 V-Log,
   S5 60p if available, interview/static, pan, walking; iPhone landscape/portrait,
   SDR/HDR/Dolby Vision and variable timing. Mark unavailable/unknown categories.
4. Run decode-only, translation and constrained homography sequentially at the same
   size/time range. Save motion JSON and baseline/corrected movies. Compute estimated
   path metrics and separately remeasure the encoded output; do not conflate them.
5. Run optional external two-pass vid.stab with the exact same input frames and color
   conversion, and record crop/zoom/smoothing/interpolation. Installed FFmpeg 8.1.2
   currently has neither vidstab filter; external tool preparation stays outside app dependencies.
6. Record median/error distribution against synthetic ground truth; residual global
   jitter (time-aware second derivative or detrended motion), rejected counts, crop,
   analysis/render time, peak physical footprint/RSS, decoder compatibility and color
   differences. Compare to baseline and provisional 30%/15% targets without moving thresholds.
7. Review actual comparison frames/video for edges, wobble, subject distortion, pans
   and color. Label snapshot-only evidence separately from full playback/human approval.
8. Run focused harness checks, full repository QA, `git diff --check`, hash recheck,
   independent findings review and final status. Keep plan active for missing gates.

Future automated coverage (M2–M6): low feature/light and moving-subject robustness;
cut resets; zero/invalid/NaN/extreme motion; irregular timing, trims/splits; crop coverage;
neutral/graded and multiple/mixed-orientation clips; removal/replacement; save/reopen,
old/future schemas; relink/corrupt cache; cancellation/project switching; rapid sliders;
missing/unsupported sources; identical-PTS preview/export correspondence and audio sync.

| Gate | Required check | Result and evidence |
| --- | --- | --- |
| Static/build | `git diff --check`; deterministic source reviewer; SDK 26.5 native app build; standalone harness compile | PASS; final diff/link check recorded in evidence report; original environment failures retained |
| Unit/integration | Full serial Swift Testing; independent harness algorithm checks | PASS: final app 382 reported / 351 passed / 31 skipped declarations, 47.458 s; five focused Python checks and standalone math pass |
| Runtime/UI | No product UI changes; future integrated playback/control checks | NOT VERIFIED; outside M0/M1 |
| Media quality | Synthetic ground truth, S5/iPhone outputs and human video review | FAIL: iPhone translation regressions, homography cut miss and neutral RGB drift; human scenario/temporal acceptance NOT VERIFIED |
| Performance | Native/reference diagnostics and original-source 15/30/60/90 s jobs | PASS measurements: native 4.996/10.131/20.862/28.823 s, peak 49–52 MiB; target-app limits NOT VERIFIED |
| Original safety | Selected source SHA-256 before/after; no originals as destinations | PASS: seven synthetic and six original inputs unchanged, including the long source |

## Decisions, discoveries, and remaining work

- 2026-10-20: Full owner plan received after initial source lookup; scope remains M0/M1.
- Initial baseline logs: `.build/video-stabilization-baseline/qa.log` (sandbox EPERM),
  `qa-unsandboxed.log` (SDK 27 missing SwiftUI macro); SDK 26.5 rerun in `qa-sdk26.log`.
  These are environment observations, not stabilization defects or passing tests.
- Local metadata inventory in `.build/video-stabilization-baseline/media-inventory.json`:
  nine DC-S5 clips (3840×2160, 24000/1001, seven 10-bit V-Log, two 8-bit Standard)
  and six iPhone 15 Pro ProRes HQ 4K 10-bit clips (multiple rotations, HLG/BT.709/
  unspecified transfer). Metadata alone does not identify scene content or certify Dolby Vision.
- Independent baseline reviewers confirmed repository/filters/selected media and healthy
  external storage (219 GiB available); disk exhaustion does not explain the build EPERM.
- Final source preservation, exact output PTS, common-triplet metrics and memory/timing
  tables were independently checked. Three harness fixes (memory label, real unequal-PTS
  generation, encoder timebase) each have independent causal red→green/revert verification.
- **Recommendation: NO-GO for M2 production-engine selection.** Native translation
  remains a provisional research baseline, but tested iPhone regressions, neutral
  color drift, homography cut failure and missing human/scenario gates block selection.
  See [the full evidence report](../../docs/archive/VIDEO_STABILIZATION_PROTOTYPE_2026-10-20.md).
  M2–M6 remain unstarted. M0 is complete; the M1 prototype is built/measured, while
  its quality acceptance remains active rather than being declared complete.

Release boundaries remain distinct: research protocol, measured real-camera prototype,
reusable tested engine, editor preview/save integration, validated delivery, and full
production acceptance. Compilation or synthetic success alone cannot close them.

Technical references: [Vision registration](https://developer.apple.com/documentation/vision/vnimageregistrationrequest),
[video compositions](https://developer.apple.com/documentation/avfoundation/avvideocomposition),
[HDR editing](https://developer.apple.com/documentation/avfoundation/editing-and-playing-hdr-video),
[vid.stab source/build/license](https://github.com/georgmartius/vid.stab),
[OpenCV](https://github.com/opencv/opencv), [Gyroflow](https://github.com/gyroflow/gyroflow),
[DC-S5 specifications](https://www.panasonic.com/uk/consumer/cameras-camcorders/lumix-mirrorless-cameras/lumix-s-full-frame-cameras/dc-s5k.html).
