# Full-resolution healing allocation target

Date: 2026-10-07
Status: accepted for target-Mac validation; broader acceptance remains active

A displayed 100-distinct-S5-RAW batch on the 8 GB M1 MacBook Air at `d2bfa30` saved 99 JPEGs and failed the one portrait with gradient/brush masks and a heal stroke. The queue continued safely and left no partial file. The nested Core Image error reports render-part requirements of 134,776,312 bytes for healing alone and 149,532,860 bytes for healing with masks, exceeding the 128 MiB focus/export allocation target.

The isolated saved-project reproduction succeeds for global edits and masks at 128 MiB, fails for healing/combined edits at that target, and succeeds for all variants with an unrestricted reference context. Preserve the photo graph, RAW precision, and output dimensions. Do not remove the heal, downsample the source before applying edits, or silently deliver an incomplete edit.

`PhotoRenderer` now lazily uses a 256 MiB context for full-resolution focus/export when an enabled, nonempty heal stroke is present and the renderer's normal target is lower. Other edits retain their normal context; a renderer already configured at 256 MiB or without a target uses that existing context. The alternate context disables intermediate caching and is released after export, focus exit, project/cache cleanup, and memory pressure. These are render allocation targets, not process-memory ceilings.

The exact RAW reproduction passes with the correction; temporarily restoring the prior renderer makes the two healing variants fail again. Bounded healed/combined JPEGs match unrestricted reference pixels (maximum channel difference 0/255 in the observed run). A portable 24 MP PNG check covers export dimensions and reference pixels; it also passes under the prior renderer and therefore is not the causal RAW reproduction. Real-RAW inputs are opt-in and unavailable in GitHub CI.

A separate missing-source reproduction confirms subject selection's failure branch left “Analyzing subjects…” in the footer. Set a completed-failure status while retaining the error message and avoiding any project edit. This corrects feedback, not segmentation quality.

The corrected release displays healed 100% focus and native subject selection successfully. Displayed delivery measurements are recorded in the [workflow report](../archive/WORKFLOW_VALIDATION_2026-10-07.md). Large/many repairs, varied native subject/sky selections, a genuine 100–200-file single shoot, and baseline/threshold performance comparison remain separate gates.
