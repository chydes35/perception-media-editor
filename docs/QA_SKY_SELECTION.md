# Sky selection — build 14

## Implementation

Select Sky creates a portable grayscale mask as one undo step. It supports local adjustments, inversion, hide/duplicate/delete, edge shift/feather/contrast, and Add to sky / Remove spill brushes. Corrections remain attached to this photo and survive project save, rotation, crop, and export. Cancel, Escape, navigation, and tool changes invalidate pending results.

Analysis is local on a separate actor using Apple's [Core ML DETR semantic segmentation model](https://huggingface.co/apple/coreml-detr-semantic-segmentation), revision `7c771f8867a479d1441ac5fb0a8de31feea76bb6`. The model is bundled with attribution and its Apache 2.0 license. No photo upload or runtime download is required. Its exact sky class is read from model metadata; this artifact uses index 187, `sky (other)`.

Input covers the whole oriented photograph at 448 × 448. A luminance-guided filter refines boundaries at up to 1536 px. Work is bounded independently of original RAW resolution. CPU/GPU inference avoids long first-use Neural Engine specialization observed on this base M1.

## Verification

Full serial regression run: **236 tests in 40 suites passed**, including native model inference on the indoor JPEG and outdoor fixture. The release build succeeded and the staged and installed app bundles passed strict code-signature verification. Build 13 was preserved as a backup.

- Asymmetric semantic rows retain top/bottom orientation, other classes are excluded, and empty results report no sky.
- Guided filtering sharpens a synthetic image boundary and preserves uniform weights.
- Sky PNGs, corrections, and refinement values round-trip through project schema 10. Photo-specific masks are excluded from sync.
- Rotated/cropped preview and full PNG export darken the selected sky while leaving the unselected area unchanged.
- Creation is one undo step; undo/redo and a subsequent brush correction preserve the Sky kind.
- Escape and switching photos reject stale completions without creating an edit.
- Native model inference correctly reports no sky on an indoor two-person JPEG. An additional local Lumix RW2 birthday scene also correctly returned no sky.
- Outdoor fixture: [Eiffel Tower and blue sky](https://commons.wikimedia.org/wiki/File:Eiffel_Tower_and_blue_sky.jpg), Nikolija Grozdanovic, [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/). Downloaded outside the repository for local testing. Visible sky is selected and the tower's main silhouette is excluded; automated point checks cover those regions. Analysis including model load took about 10 seconds in the focused run on this M1. This is not a general latency benchmark.
- Installed-app check: Select Sky displayed progress and completed with a red overlay aligned to the outdoor fixture. Sky 1, REFINE SKY, edge controls, Add to sky, and Remove spill were present. Remove spill activated Erase mode; wheel scrolling over the photo zoomed from 1.0× to 2.6× while that mode was active. The project saved with a Sky mask in schema 10. First app initialization took longer than the focused test; further first-use latency profiling remains open.

## Remaining quality work

Fine lattice openings in the tower are mostly omitted. Guided filtering cannot reconstruct details missed by semantic segmentation. Broader validation is still needed for foliage, hair, sunsets, overcast skies, reflections, and varied RAW cameras. The abstract Sonoma wallpaper was only a smoke test and is not evidence of photographic selection quality.

Build 14 saves schema 10; builds 13 and earlier cannot reopen those newly saved projects. Use a project copy when comparing versions.
