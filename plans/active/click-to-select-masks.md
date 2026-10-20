# Click-to-select masks (SAM 2.1) and better selection edges

Status: active (planned; nothing implemented, no model downloaded)  
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
- Input/output contract, read from Hugging Face's open-source SAM2 Studio (`SAM2.swift`, Apache-2.0): encoder takes `image` (1024 × 1024) and returns `image_embedding`, `feats_s0`, `feats_s1`; prompt encoder takes `points` (`[1,N,2]` float32, in 1024-space) and `labels` (`[1,N]` int32) and returns `sparse_embeddings`, `dense_embeddings`; mask decoder takes those plus the three encoder outputs and returns `scores` and `low_res_masks` (`[1,numMasks,h,w]`); the best mask is the one with the highest score; the low-res mask is upsampled first and thresholded after. The reference stretches the image to 1024 × 1024 (no letterbox) and uses `.cpuAndGPU`. Label values for include/exclude and the mask resolution are checked on the real model in step 2, not assumed.

## Implementation steps

1. **Model delivery (needs the user's go-ahead to download).** `scripts/prepare-sam-model.sh` (pinned revision, per-file SHA-256, compile to `.mlmodelc`), build-app copy, license notice in `Resources/ModelNotices/SAM2`. Verify the three packages' real input/output names and shapes with `MLModel.modelDescription`, and record them here.
2. **Engine behind a protocol.** `PromptableSegmenter` (encode a photo once, then decode masks for a list of labelled points) with a Core ML implementation and a deterministic fake for tests. Pure, testable pieces: mapping a displayed click to 1024-space through crop/rotation, upsample-then-threshold post-processing, orientation of the returned mask, an embedding cache keyed by photo with a memory cap.
3. **Memory and compute.** Load the models lazily off the main actor, compare `.cpuAndGPU` with `.all` (Neural Engine) for latency and peak footprint on the target Mac, unload after idle and on memory pressure (the store already has a pressure handler).
4. **UI: a "Click to select" tool in the Masks panel** next to the existing subject/sky tools: include click, ⌥-click exclude, hover preview if latency allows, undo last click, accept to add a `SubjectMask`; reuse `SubjectPickingLayer`'s coordinate mapping and overlay rendering.
5. **Edges.** Run the existing guided matte (`SubjectEdgeMatting`) on the SAM mask with the full-resolution photo as the guide; keep the existing shift/feather/contrast controls.
6. **Validation on real files.** The five RAWs from the October 8 report plus the ivy shoot; images recorded for the group, branch sky, fur, fabric and portrait cases; timings and peak memory; honest notes on what is still weak.
7. Tests, docs, status, commit; open or extend the pull request.

## Safety and performance

- Original media: untouched. Inference reads a decoded working copy; masks are written only into the project's mask data, as today.
- Privacy: the model runs on-device; nothing is sent anywhere.
- Memory: three float16 models (about 94 MB of weights) plus embeddings (about 8 MB per photo at 1024 px) are small beside the 2,560 px working copies, but the 8 GB M1 is the constraint, so models load lazily, the embedding cache is capped to the photo being edited and one neighbor, and everything is released under memory pressure.
- Responsiveness: all inference runs off the main actor with cancellation, like `SubjectAnalysisService`; a stale result (the user moved to another photo, or clicked again) is discarded by request id, the same guard the Vision path already uses.
- App size: about 94 MB larger.

## Verification

| Gate | Required check | Result and evidence |
| --- | --- | --- |
| Static/build | `git diff --check`; Swift build; app bundle includes the model | PENDING |
| Unit/integration | Click mapping through crop and rotation, post-processing, cache limits, include/exclude state, stale-result guard (fake segmenter); opt-in real-model tests | PENDING |
| Runtime/UI | Click to select, include/exclude, undo, accept, adjust, save and reopen, in the built app | PENDING |
| Media quality | The October 8 cases redone on the real files, with inspected images | PENDING (visual only) |
| Performance | First-click and later-click latency, peak footprint on the 8 GB M1, `.cpuAndGPU` vs `.all` | PENDING |

## Decisions, discoveries, and remaining work

- **Why SAM 2.1 Small first:** it is the model Apple's own Core ML conversion and the reference app ship by default, about 94 MB, and the research found it the only commercially licensed promptable segmenter with an official Core ML build. Tiny is smaller and Base+ better; they are compared in step 3 only if Small is too slow or too weak.
- **Why points only:** the reference code handles only points; box prompts use a different label convention that has not been verified for these packages.
- **Why not replace Vision:** Vision stays as the one-click "find subjects" path (fast, no model download in the build); SAM adds the ability to pick anything. Both produce the same `SubjectMask`.
- **Downloading the model needs the user's approval** (about 94 MB from Hugging Face). Nothing has been downloaded.
