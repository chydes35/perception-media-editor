# V0.3.3 Milestone — Shared Clip Color

## Build contract

This increment closes the V0.3.2 reorder-selection defect and establishes one non-destructive adjustment model across photos and timeline clips. It preserves the existing three-pane video workspace, timeline composition playback, reference-file project format, and built-in Perception presets.

## Delivered

- Persistent per-clip `PhotoAdjustments` stored in `videoAdjustmentsByClipID`
- Project schema 3 with schema 1/2 decoding compatibility
- Shared Core Image graph for photo rendering and video-frame filtering
- Per-clip exposure, contrast, highlights, shadows, temperature, tint, vibrance, saturation, sharpness, and vignette controls
- Built-in and user Perception preset application for timeline clips
- Clip-color reset without modifying source media
- Filtered timeline playback through `AVVideoComposition`
- Reorder behavior that moves the playhead with the reordered clip and keeps that clip selected
- V0.3.3 build 6 metadata and milestone documentation

## Acceptance evidence

| Requirement | Result | Evidence |
| --- | --- | --- |
| Reordered clip remains selected | Pass | Moving the first clip later moved the playhead to its new three-second start and preserved its inspector selection. |
| Photo and video use the same adjustment values | Pass | `PhotoAdjustments` and `MediaColorRenderer` drive both render paths. |
| Clip color is isolated by sequence time | Pass | A +2.12 EV blue clip rendered bright cyan while the following neutral orange clip remained unchanged. |
| Presets work on video clips | Pass | Quiet Monochrome changed the selected clip to grayscale and populated its shared adjustment values. |
| Reset returns the clip to neutral | Pass | All clip controls returned to zero and neutral playback returned. |
| Adjustments persist | Pass | A saved schema 3 project reopened with the adjusted clip at +2.12 EV. |
| Older projects remain readable | Pass | Model checks remove the schema 3 color key from a schema 2 fixture and confirm a neutral default. |
| Split clips preserve color | Pass | Split logic copies the original clip's adjustment record to the new segment. |
| Deleted clips do not leave color records | Pass | Ripple delete removes the matching adjustment entry. |
| Production build is runnable | Pass | Model checks, debug build, release build, and strict code-sign verification passed. |

## Assumptions and intentional boundaries

- Photo rotation and crop metadata are not applied to video clips; the shared video surface is limited to light, color, sharpness, and vignette.
- Color is currently a timeline-preview capability because video export is not implemented yet.
- A timeline composition rebuild is requested as adjustment values change. Cancellation keeps only the latest request, but long projects still need performance profiling.
- Sequence framing continues to use the first playable clip's preferred transform; mixed-orientation fitting remains release-hardening work.

## Review instructions

1. Open a project containing two visually distinct clips.
2. Select one timeline clip and change Exposure or apply Quiet Monochrome under **CLIP COLOR**.
3. Scrub across the cut and confirm the other clip remains neutral.
4. Save, reopen, and select the adjusted clip to confirm its values persist.
5. Move the selected clip earlier or later and confirm it remains selected at its new timeline start.

The implementation is ready for design review, followed by focused QA of mixed clip durations, preset transitions at cuts, persistence, and adjustment responsiveness.
