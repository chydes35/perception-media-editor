# Video golden frames

`old-ci-path-graded.png`, `old-ci-path-graded-no-hsl.png` and `old-ci-path-neutral.png` are frame 3 of the 192×108 color-pattern movie
(`writeColorPatternMovie` in `Tests/PerceptionEditorTests/VideoTestSupport.swift`: ProRes 422, tagged
Rec. 709), as `AVAssetImageGenerator` showed it through the **CIFilter-handler composition that the
custom compositor replaced** (commit 28be3c0, `TimelineCompositionService.makePlayerItem` with
`quality: .export`).

- `graded`: with `goldenGradeAdjustments()` (exposure, contrast, highlights, shadows, temperature,
  tint, vibrance, saturation, curves, HSL, sharpness, vignette), so it went through
  `AVVideoComposition(applyingCIFiltersWithHandler:)` and an 8-bit BGRA output.
- `graded-no-hsl`: the same without HSL (captured later from commit 28be3c0), because the exact HSL
  kernel intentionally replaced the old 48³ cube and its interpolation error.
- `neutral`: no adjustments, so AVFoundation's own Rec. 709 decode with no video composition.

They are the record of the old look. `TimelineVideoCompositorTests` compares the new compositor with
them. Do not regenerate them from the new code; that would make the comparison circular.
