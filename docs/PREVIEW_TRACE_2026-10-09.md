# Cold RAW preview tracing — October 9, 2026

Started from clean `12440f4`. The previous lifecycle fix is present. This continuation adds observation and stress coverage; it does not claim to have corrected the earlier persistent black canvas.

## Investigation

`PhotoPreviewDiagnostics` is disabled in normal builds. Opt-in tests use `PME_PREVIEW_DIAGNOSTICS=1`; an isolated QA bundle can set Boolean `PerceptionPreviewDiagnostics` before signing. Local OSLog metadata distinguishes unavailable source/bitmap, a completed bitmap with/without histogram pixels, store publication/discard, and SwiftUI canvas appearance/image/mode/overlay changes. Request IDs and project generations are ephemeral; paths, image pixels and saved-project contents are absent. Disabled messages are not evaluated. Enabled histogram diagnostics reuse the existing sample rather than decoding another image. Rendering, cancellation, cache targets and publication decisions remain unchanged.

The new opt-in RAW stress check replaces the project twelve times while a cold preview task is pending, alternates mask overlay state and clears expendable renderer resources. With the pinned model supplied, a separate actor retains one sky model across the loop and runs analysis at iterations 0/4/8, matching the application's model lifetime more closely than a temporary one-shot model. The test compares edited pixels and saved adjustments with the initial preview and verifies the copied RAW SHA-256. Timing is not an acceptance assertion; the trace records whether old native work ran before cancellation.

The first focused run (without model) passes four tests in 40.262 seconds; the retained-model run passes in 107.095 seconds. Across those captured focused runs, **84 actual renderer frames have nonempty histograms**, and **30 obsolete completions are discarded**; three retained-model analyses finish. Twelve cold replacement cycles per run and eight export/reopen cycles per run match their initial edited pixels. No persistent black frame is reproduced in those integration runs. Synthetic paused-worker test results with an empty histogram are distinguishable from actual renderer frames in the trace.

## Displayed reproduction

The traced release candidate reproduces the persistent black edited canvas after fresh Select Sky → Save → Export → New → Open → Photo → Sky 3. The image remains black in a second observation. Renderer completion at 05:30:35 reports 1201 × 1800, a nonempty histogram with 256/252/252 nonzero RGB bins, and a mask overlay. Store publication and canvas observation report both preview images present and `busy=false`. Original displays correctly; returning to Edited restores the photo with **no additional renderer/store events**. A second New/Open/Photo/Sky 3 cycle displays correctly. This isolates a display-invalidation lead for this intermittent reproduction, rather than an unavailable source or missing publication. A temporary image-view identity experiment (`.id(ObjectIdentifier(image))`) passes once, but reverting to the saved baseline executable also passes, including a repeat from the original two-mask fixture. The comparison cannot establish causality; the identity edit is removed. The retained changes are tracing and stress coverage only.

The disposable project preserves schema 10, media and complete adjustments after reopening (only `updatedAt` changes). The earlier QA project is byte-identical to its pre-UI copy. The UI JPEG fully decodes to 4000 × 6000 PNG with `sips`; original and copied RAW SHA-256 match the inventory. Fresh analysis/export peak footprint is 1,176,669,696 bytes (1.096 GiB); post-export 355,749,824 bytes (339.3 MiB), post-New 266,260,160 bytes (253.9 MiB). These observations do not establish agreed performance thresholds.

## Gates

| Gate | Result and scope |
| --- | --- |
| Focused integration | **PASS** — lifecycle regressions, cold RAW replacement/cache cleanup, retained native model and existing export/reopen checks |
| Trace privacy/availability | **PASS** — captured renderer and store events; no source paths/file URLs/RAW filenames in the selected-category trace |
| Full QA/build | **PASS** — `./scripts/qa.sh`: 316 reported tests in 68 suites, **298 executed / 18 skipped**, 169.875 seconds; source/diff review and debug app build pass. Tracing is disabled; copied RAW/model stress and export/reopen inputs are enabled |
| GitHub QA | **PASS** — [code-head run](https://github.com/chydes35/perception-media-editor/actions/runs/37919286297) at `ec68fed`: 316 reported, 288 executed / 28 skipped, 38.016 seconds; build/source checks pass. Private RAW/model workflow inputs absent |
| Isolated release build/package | **PASS** — `swift build --disable-sandbox --scratch-path .build -c release --product PerceptionEditor` (58.04 seconds), candidate `codesign --verify --deep --strict` and `plutil -lint`; installed app unchanged |
| Traced release UI/media/integrity | **FAIL / PASS** — persistent edited black canvas reproduced; save/decoded export and source integrity pass |
| Whole-app performance | Observed above; matched thresholds and genuine full-shoot acceptance **NOT VERIFIED** |
| Original persistent black canvas | **FAIL** — reproduced; causal correction **NOT VERIFIED**; [recovery plan](../plans/active/preview-reopen-recovery.md) remains active |

The test-only fixture `TraceQA.pmedit` is cloned under `.build/preview-trace-validation/` before UI work to avoid autosaving new masks into the earlier QA fixture. Logs use `/private/tmp/perception-preview-{stress-focused,retained-model,trace-full-qa}.log`; local category capture and summaries remain under `.build/preview-trace-validation/`. These local fixtures and traces are not uploaded to GitHub.

Next: isolate the native image/display invalidation responsible for the observed black canvas. Inspect layout/layer and image-resource lifetime during a failing frame and prove any correction with a failing-before/passing-after comparison. Remaining Phase 3 fine-edge/shaded-sky and group-quality acceptance follows the reliability investigation.
