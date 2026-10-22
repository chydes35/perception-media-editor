# Click-to-select masks (SAM 2.1) and better selection edges

Status: active (steps 1–6 done except the October 8 branch-sky case and click markers; checked in the built app and on real RW2 files)

Roadmap: [Phase 3 masks and healing](../../docs/ROADMAP.md), image-quality program Q3 ([research](../../docs/research/PHOTO_PIPELINE_SOTA.md))

Owner: lead agent

## User outcome and acceptance

Today a subject mask comes from Apple Vision's foreground and person detectors. The photographer can only choose what Vision found, and the [October 8 real-RAW report](../../docs/archive/SELECTION_QUALITY_2026-10-08.md) recorded where that fails: a group of people (only one child had a candidate), sky seen through fine branches (most blue gaps missed), and hair/fur with spill into the background.

After this plan the photographer can **click anything in the photo and get its mask**: one child in a group, a pumpkin, a patch of sky, a dog. Further clicks add to the selection (include) or carve parts out (exclude, ⌥-click). The result is an ordinary subject mask, so the existing edge controls, brush corrections, local adjustments, presets, crop/rotation handling, save/reopen and export all work unchanged.

Acceptance:

1. Clicking a point returns a mask of the object under it; the first click on a photo shows a mask within a few seconds, later clicks on the same photo within about a second, on the 8 GB M1 (measured, recorded below).
2. Include and exclude clicks refine the mask; undo removes the last click; the accepted mask is a `SubjectMask` PNG at full photo orientation.
3. The three failure cases in the October 8 report, redone on the same five RAW files: every visible child in the indoor group selectable by one click each; the branch sky selectable with a few include clicks; hair/fur edges inspected at 100% zoom with the existing edge controls and a guided-matte refinement. These are **visual** results, recorded with the images and honest about what is still weak; no metric will be presented as proof of photographic quality.
4. No `.pmedit` schema change (the mask is stored exactly as today); presets, sync and export behave as for existing subject masks.
5. Peak memory with the model loaded stays inside the 8 GB budget with a 2,560 px working copy and the preview open; the model unloads under memory pressure and after idle.
6. Original media is never written; the model never leaves the machine and nothing is uploaded.

Out of scope for this plan: box and text prompts (the reference app only uses points, and box encoding is unverified), video, a "select everything" auto-segmenter, BiRefNet matting (a possible follow-up for hair, only if the guided matte is not enough), face-part parsing, depth masks.

## Current state and affected contracts

- `SubjectAnalyzer.swift` runs Vision (`VNGenerateForegroundInstanceMaskRequest`, `VNGeneratePersonInstanceMaskRequest`, group recovery) and returns `SubjectAnalysis` candidates; `EditorStore+Subjects.swift` drives pick/preview/add; `SubjectPickingLayer.swift` maps a click through crop and rotation (`PhotoComparisonView.normalizedPoint`, `ImageGeometry`); `SubjectEdgeMatting.swift` refines edges with a guided matte; `SkyAnalyzer.swift` is the existing bundled Core ML model (DETR) and the pattern to follow.
- `MaskShape.subject(SubjectMask)` stores a grayscale PNG plus brush strokes and edge settings (`LocalMasks.swift`); this is the only mask data contract this plan touches, and it is unchanged.
- Model bundling pattern: `scripts/prepare-sky-model.sh` downloads a pinned Hugging Face revision, checks SHA-256 per file, compiles to `.mlmodelc`; `scripts/build-app.sh` copies it into the bundle; notices go in `Resources/ModelNotices`. SAM follows the same pattern.
- The model, from the research and verified against the Hugging Face API on 2026-10-20: `apple/coreml-sam2.1-small`, Apache-2.0, revision `883f5787eb0be35ce6965907a8bc1f5320a5a02e` (last modified 2024-10-01), three float16 packages: image encoder 81.5 MB, mask decoder 10.3 MB, prompt encoder 2.1 MB, about **94 MB** in all. Meta's SAM 2.1 is Apache-2.0.
- Input/output contract, read from Hugging Face's open-source SAM2 Studio (`SAM2.swift`, Apache-2.0): encoder takes `image` (1024 × 1024) and returns `image_embedding`, `feats_s0`, `feats_s1`; prompt encoder takes `points` (`[1,N,2]` float32, in 1024-space) and `labels` (`[1,N]` int32) and returns `sparse_embeddings`, `dense_embeddings`; mask decoder takes those plus the three encoder outputs and returns `scores` and `low_res_masks` (`[1,numMasks,h,w]`); the best mask is the one with the highest score; the low-res mask is upsampled first and thresholded after. The reference stretches the image to 1024 × 1024 (no letterbox) and uses `.cpuAndGPU`.

**Verified on the real model, 2026-10-20** (nine files downloaded at the pinned revision, 93,893,011 bytes; all sizes match and the six large files' SHA-256 equal Hugging Face's published values; the three 617-byte manifests are pinned from that verified download):

- Encoder: `image` is a 1024 × 1024 BGRA pixel buffer; outputs `feats_s0` `[1,32,256,256]`, `feats_s1` `[1,64,128,128]`, `image_embedding` `[1,256,64,64]`, all float16, about 8.4 MB in all.
- Prompt encoder: `points` `[1,N,2]` and `labels` `[1,N]` with N from 1 to 16 (the label dimension is a range of 1…16); outputs `sparse_embeddings` `[1,N+1,256]` and `dense_embeddings` `[1,256,64,64]`. The reference app's float32 points and int32 labels work.
- Mask decoder: `sparse_embedding` is an enumerated set `[1,2,256]` … up to 17 rows; outputs `scores` `[1,3]` and `low_res_masks` `[1,3,256,256]` (three nested candidates).
- Label `1` includes and `0` excludes; an exclude click's effect is **local** (it carved a visible notch at the click, not the whole headband), so refinement takes a few clicks and needs instant feedback.
- **Compute units: CPU and GPU only.** Loading the encoder with `.all` took **538.8 s**; the mask decoder fails on `.all` (`conv_transpose` output-shape error). `.cpuAndGPU` loads in 0.1–0.9 s.
- **Timings on the target M1 (cpuAndGPU):** encoder 0.57–0.83 s per photo, prompt encoder 8–13 ms, mask decoder 16–21 ms warm per click. The very first encoder run after a cold system took 11.9 s (a one-time GPU-program compile that later runs did not repeat), and the first decoder call 1.7–3.6 s, so the first use needs a warm-up step with visible progress.
- **One click returns nested candidates**: on the ivy shoot (P1107269 at 2048 px), one click on the baby's face gave the face (score 0.86), the face with headband, and the whole baby (score 0.34) with a clean silhouette including the bow and the hand. The reference app takes the highest score, which would always return the face, so the tool must let the photographer choose the granularity (part, object, whole) and should not default to the top score alone.
- Not yet checked: peak memory with the models loaded next to a 2,560 px working copy, quality on hair/fur and sky gaps, orientation handling through crop and rotation.

## Implementation steps

1. **Model delivery. DONE 2026-10-20** (the user approved the download). `scripts/prepare-sam-model.sh` (pinned revision, per-file SHA-256, skips files already verified) and `scripts/compile-coreml-package.swift` compile the three packages to `.mlmodelc`; `scripts/build-app.sh` copies them into the app's `Resources/Models`; notice and Apache-2.0 license in `Resources/ModelNotices/SAM2`. Real input/output names and shapes recorded above. Run against the verified files it downloads nothing and compiles all three in 13 s. A fresh checkout downloads about 94 MB once on its first `build-app.sh`.
2. **Engine behind a protocol. DONE 2026-10-20** (`PromptableSegmenter.swift`, `SAM2Segmenter.swift`, `PromptableSegmenterTests`; the opt-in real-model test, `PM_SAM_MODELS=.build/models`, selected a synthetic disc: 3 candidates ordered part to whole, first encode in that run 4.1 s). Photo orientation and click-through-crop mapping stay in the UI step; the engine takes clicks in the oriented photo's 0…1 coordinates. `PromptableSegmenter` (encode a photo once, then decode masks for a list of labelled points) with a Core ML implementation and a deterministic fake for tests. Pure, testable pieces: mapping a displayed click to 1024-space through crop/rotation, upsample-then-threshold post-processing, orientation of the returned mask, an embedding cache keyed by photo with a memory cap.
3. **Memory.** Load the models lazily off the main actor on `.cpuAndGPU` (the Neural Engine is ruled out above), run a visible warm-up on first use, measure peak footprint beside a 2,560 px working copy on the target Mac, unload after idle and on memory pressure (the store already has a pressure handler).
4. **UI: a "Click to select" tool in the Masks panel** next to the existing subject/sky tools: include click, ⌥-click exclude, a granularity choice among the three candidates (part, object, whole), live preview after each click (a decode is about 20 ms), undo last click, accept to add a `SubjectMask`; reuse `SubjectPickingLayer`'s coordinate mapping and overlay rendering.
5. **Edges.** Run the existing guided matte (`SubjectEdgeMatting`) on the SAM mask with the full-resolution photo as the guide; keep the existing shift/feather/contrast controls.
6. **Validation on real files.** The five RAWs from the October 8 report plus the ivy shoot; images recorded for the group, branch sky, fur, fabric and portrait cases; timings and peak memory; honest notes on what is still weak.
7. Tests, docs, status, commit; open or extend the pull request.

## Safety and performance

- Original media: untouched. Inference reads a decoded working copy; masks are written only into the project's mask data, as today.
- Privacy: the model runs on-device; nothing is sent anywhere.
- Memory: three float16 models (about 94 MB of weights) plus embeddings (about 8 MB per photo at 1024 px) are small beside the 2,560 px working copies, but the 8 GB M1 is the constraint, so models load lazily, the embedding cache is capped to the photo being edited and one neighbor, and everything is released under memory pressure.
- Responsiveness: all inference runs off the main actor with cancellation, like `SubjectAnalysisService`; a stale result (the user moved to another photo, or clicked again) is discarded by request id, the same guard the Vision path already uses.
- App size: about 94 MB larger.

## Results so far (2026-10-20, ivy P1107269, M1, built app)

- Probe (`ClickSelectionProbe`, real model, 1536 px working copy): peak process memory 284 MB with all three models loaded; encode 2.9–4.1 s the first time in a test process.
- In the app: first "Click to Select" took roughly 15–40 s to become ready (cold model load and GPU compile, not timed precisely); then each click showed its mask within about 1.5 s. A click's model passes take about 0.1 s; the rest was upsampling and PNG work, which is slow in debug builds and not yet profiled in release. NOT VERIFIED against the 1 s goal.
- Quality on this photo: baby face / whole baby (bow and torso, clean silhouette) / pumpkin whole / yellow flower cluster whole; undo, size picker and Accept (one `Subject` mask, one history step) all worked. The default mask now prefers the most confident one under a third of the frame. One-click "whole" on the lawn-side flower returns a blob of lawn as the largest candidate, which is why the default avoids large masks.
- **Latency, release build (probe):** a click takes 0.08 s (0.2 s for the first click of a photo), and fitting the edge on Accept takes 0.2-0.3 s; first-photo preparation 3-4 s after the models are warm. The earlier 0.8-0.9 s figures were from debug builds. The in-app click-to-overlay time is not measured separately (the overlay render is extra).
- **Edges:** Accept now fits the mask edge with the existing guided matte (`SubjectEdgeMatting`) at 1536 px. On the dog and hair crops the refined mask follows the fur and hair silhouette closely; no metric is claimed.
- **Group of children (P1107371, three clicks):** each child is selectable with one click using the Whole size (girl with legs, baby, boy with legs); the default size can pick the garment instead of the person, so the size picker matters. Hair: a click on hair selected the hair (and headband) as the smallest mask.
- **Dog and girl (P1107251):** Object gives the dog with a clean silhouette; Whole merges dog and girl into one speckled mask. Plant with fine branches (coleus): Whole selects the whole plant including its branches, but the default (smallest, highest-scoring) mask is a few leaves, so the photographer widens it.
- The default mask is the most confident one under a third of the frame, or the smaller one when within 0.05 of it.
- Not yet done: the October 8 branch-sky case (the original five RAWs were not found; similar frames were used instead), click markers drawn on the photo, idle unload observed in the app.

## Verification

| Gate | Required check | Result and evidence |
| --- | --- | --- |
| Static/build | `git diff --check`; Swift build; app bundle includes the model | Model script and compile PASS (13 s, three `.mlmodelc`); `build-app.sh` now copies them but the app bundle with the models has not been rebuilt yet. PENDING |
| Unit/integration | Click mapping through crop and rotation, post-processing, cache limits, include/exclude state, stale-result guard (fake segmenter); opt-in real-model tests | PENDING |
| Runtime/UI | Click to select, include/exclude, undo, accept, adjust, save and reopen, in the built app | PENDING |
| Media quality | The October 8 cases redone on the real files, with inspected images | PENDING (visual only) |
| Performance | First-click and later-click latency, peak footprint on the 8 GB M1, `.cpuAndGPU` vs `.all` | PENDING |

## Decisions, discoveries, and remaining work

- **Why SAM 2.1 Small first:** it is the model Apple's own Core ML conversion and the reference app ship by default, about 94 MB, and the research found it the only commercially licensed promptable segmenter with an official Core ML build. Tiny is smaller and Base+ better; they are compared in step 3 only if Small is too slow or too weak.
- **Why points only:** the reference code handles only points; box prompts use a different label convention that has not been verified for these packages.
- **Why not replace Vision:** Vision stays as the one-click "find subjects" path (fast, no model download in the build); SAM adds the ability to pick anything. Both produce the same `SubjectMask`.
- **The model was downloaded with the user's approval** (about 94 MB from Hugging Face, 2026-10-20) and is cached in `.build/models` (git-ignored) and in the scratchpad.
