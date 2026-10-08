# Real-RAW selection quality — October 8, 2026

Status: active acceptance; sampled selection quality has failures.

## Scope and method

Start from `79310cc` on the Apple M1 MacBook Air / 8 GB, macOS 26.6.2. Six cases use five distinct disposable DC-S5 RW2 files from the previously hashed 100-photo workload. The indoor-group RAW is also a negative sky control. This is not a genuine single shoot or a mixed-camera matrix. Application behavior and project schema remain unchanged.

The opt-in `SelectionQualityTests` diagnostic runs inference sequentially, saves native candidate/union masks, serializes and reloads raster edits, generates production previews/overlays, and exports 2,048-pixel PNGs with a -1 EV masked adjustment. A nonempty mask and successful export establish structural behavior, not photographic correctness. Expected no-sky/no-subject outcomes are recorded; decode/model/render errors fail the runner. Local private fixtures and generated images remain under `.build/selection-quality-validation/`, outside Git.

## Visual observations

| Case | Observation | Quality result |
| --- | --- | --- |
| Indoor group | Only the right foreground child is selected; most visible people receive no candidate | FAIL for group coverage; detected-foreground union is internally consistent |
| Fine branches / blue sky | Mask mainly covers the upper-right patch, missing visible blue gaps elsewhere | FAIL for this difficult sky case; no full sky-separation claim |
| Dog fur | Broad head/body coverage is plausible, with a soft boundary requiring inspection/refinement; native candidate is named `Person 1` | Partial evidence; animal candidate naming is misleading; fine fur NOT VERIFIED |
| Fabric and fingers | Main silhouette, headdress and fingers are retained; fringe/spill around patterned fabric and soft boundaries need refinement | Partial evidence; translucent fabric and fine edge acceptance NOT VERIFIED |
| Portrait fine hair | Face/body covered, with soft spill into the foreground toy area | Partial evidence; fine-hair/spill quality remains open |
| Indoor sky negative control | No sky detected | PASS for this negative control only |

The group and sky misses are inference-quality observations, not evidence that mask serialization or export lost pixels. Native model replacement, cropping/detection strategies or refinement tuning need a separately bounded implementation and representative positive/negative fixtures. Do not change default thresholds based on one photo. In the meantime, inspection and Add/Remove refinement remain necessary for these cases.

## Verification and remaining work

| Gate | Result and evidence |
| --- | --- |
| Static/build | PASS — `./scripts/qa.sh` source/diff checks and debug app build |
| Unit/integration | PASS — 296 reported cases/59 suites, 291 executed/five skipped, 140.894 seconds with selection/workflow RAW and native fixtures enabled |
| Structural media | PASS — five mask cases serialize/reload unchanged, aligned overlays and 2,048-pixel edited exports; negative indoor sky returns no sky |
| Sampled visual quality | FAIL — group coverage and branch-heavy sky misses; portrait foreground spill observed |
| Integrity | PASS — five originals and their disposable copies match pre-run SHA-256 |
| Runtime/UI | NOT VERIFIED — no fresh displayed app pass in this diagnostic-only step |
| Performance acceptance | NOT VERIFIED — no new whole-app profile, agreed thresholds or genuine single-shoot workload |
| GitHub CI | Final-head result is recorded on [draft PR #7](https://github.com/chydes35/perception-media-editor/pull/7); CI skips private fixture inference |

The repeated sequential inference observations were 2.24 s for group, 9.87 s for branch sky, 2.35 s for fur, 1.93 s for fabric, 2.31 s for portrait and 0.73 s for indoor sky rejection. These exclude preview/export work and are neither UI latency nor an accepted limit. Five source masks plus the negative control were inspected together with their generated overlays; fabric edited export was visually checked. No pixel-level ground-truth annotation or broad preview/export equivalence is claimed. The automated full gate log is `/private/tmp/perception-selection-quality-full-qa.log`.

 Fresh displayed UI and process-memory measurements are not repeated because this step changes only diagnostic tests/documentation; the prior [target-Mac report](WORKFLOW_VALIDATION_2026-10-07.md) is historical evidence at its recorded revision.

Broad Phase 3 quality remains active: fine hair, translucent detail, dense groups, sunsets, overcast skies, foliage, fine structures, reflections and mixed cameras. A genuine 100–200-photo shoot path is requested from the user; none has been provided in this step. Do not substitute repeated or mixed-folder photos. Next implementation priority is group candidate coverage and branch-heavy sky misses, with annotated real-photo reference cases before changing the inference pipeline.

## Reproduce locally

Create a JSON array containing `name`, `path` (read-only disposable RAW copy) and `kind` (`subject` or `sky`). Set `PME_SELECTION_MANIFEST` to that file, `PME_SELECTION_OUTPUT_DIR` to a disposable artifact directory, and `PERCEPTION_SKY_MODEL_PATH` to the pinned compiled model. Close the app and run `./scripts/test.sh --no-parallel --filter SelectionQualityTests`. Artifacts use numbered case folders; `observations.json` records candidates, expected empty outcomes and analysis time. Inspect source, mask, overlay, edited preview and export together. The masks are local diagnostic images, not annotated ground truth.
