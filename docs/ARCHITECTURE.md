# Architecture

Perception Media Editor is a native Apple Silicon macOS app built with SwiftUI and AppKit, Core Image for photo rendering, and AVFoundation for its existing video timeline/playback engine. Development follows the photo-first roadmap.

## Core rule

Original media is never modified. A `.pmedit` project stores references to the originals plus adjustment metadata. Preview and export reconstruct the result from those instructions.

## Current modules

- `EditorModels.swift`: versioned project, media, adjustments, crop, and preset data.
- `ProjectDocument.swift`: atomic JSON project persistence and schema guard.
- `EditorStore+Project.swift`: explicit save state and shared manual/autosave persistence; failed saves preserve the last-saved snapshot and expose retry/Save As recovery.
- `ExportFileSafety.swift`: original-file protection by canonical path and device/inode identity, plus temporary-sibling rendering and atomic final output publication.
- `BatchExport.swift`, `EditorStore+Export.swift`, and `ExportWorkspace.swift`: validated batch JPEG settings, stable project-order selection, unique output planning, sequential export state, progress/cancel, and per-file results. Batch publication creates a completed file only if the destination is still unused, so a late collision cannot overwrite a deliverable.

Batch queue verification can inject a file-level asynchronous exporter through `EditorStore` initialization. The app's default still uses one sequential `PhotoRenderer` with the 128 MB allocation target. Disposable fixture tests pause after the atomic publisher writes its temporary JPEG to verify mid-file Stop cleanup, continuation after a real missing-source failure, same-project reopen identity, late callbacks, and replacement-queue ownership. These checks establish queue boundaries, not RAW render speed or photographic quality.
- `PhotoUndoHistory.swift`: changes for affected assets, with one 100-step / 32 MiB estimated retention budget shared by undo and redo. Accounting includes curve points, brush/correction points, subject/sky PNG bytes, and healing/clone points. Session history also has a 16 MiB estimated shoot-wide budget; these budgets do not measure total resident memory.
- `PhotoRenderer.swift`: an actor that renders previews (working copies in GPU-shared half-float pixel buffers, one edited RAW variant per photo, one full-resolution buffer for the 100% view), histograms, thumbnails, and exports off the main thread. Editing uses a working copy capped at 2560 px (RAW files decode through `CIRAWFilter` at reduced scale into a linear half-float buffer), and only four working copies stay in memory. Full-resolution decodes are reserved for 100% focus and export. RAW thumbnails use the camera's embedded JPEG preview.
- `MediaColorRenderer.swift`: shared Core Image adjustment graph used by photo rendering and timeline clip playback.
- `EditorStore.swift`: main-actor application state and file-panel workflows. Preview requests collapse while a render is in flight, so slider drags render only the latest values. Unsaved changes are tracked against the last saved project and confirmed before New, Open, and Quit.
- Workspace views: Library, Cull, Photo, Video, Export, and Agents.
- `HistogramView.swift`: accessible RGB histogram rendered from the edited image pipeline.
- `PhotoComparisonView.swift`: original, edited, split, and side-by-side presentation modes.
- `LocalMasks.swift`: the mask model (linear, radial, brush, subject, and sky shapes, each with its own adjustments) and the renderers that turn a mask into a grayscale image. Gradients are procedural and eased in linear light. Brush strokes are painted as soft dabs (lightest-wins for painting, darkest-wins for erasing) and cached, and painting continues from the previous raster so a stroke costs a few milliseconds however many strokes exist. Subject and sky masks are bounded grayscale PNGs with cached decode and the same brush correction path. Edge shift, feather, and contrast refine the corrected mask on this bounded raster before scaling to the photo; shift and feather are stored as fractions of its longer side. Masks are stored in the original photo's coordinates.
- `ImageGeometry.swift`: maps positions between the original photo and the finished picture (rotation, straighten, crop), sharing its crop math with `MediaColorRenderer`. Verified against real renders, since the mask handles and the pixels must agree.
- `EditorStore+Masks.swift`, `MaskEditingLayer.swift`, and `MaskPanel.swift`: mask creation and editing, the handles and brush cursor drawn over the photo, and the panel.
- `SubjectAnalyzer.swift`, `EditorStore+Subjects.swift`, and `SubjectPickingLayer.swift`: analyze an oriented photo with Vision's person and foreground instance requests on a separate actor, select an instance from a click or the list, and persist its soft mask in the project. The overview is the maximum of the retained candidate masks, merged incrementally to bound memory. Hover previews are debounced, guarded against stale completion, and cached with a four-overlay limit. Source-to-finished geometry keeps selections and previews aligned through rotation and crop.
- `SkyAnalyzer.swift`, `SkyEdgeRefiner.swift`, and `EditorStore+Sky.swift`: load the bundled DETR semantic segmentation model lazily on a separate actor, identify its exact sky class from model metadata, and detect sky across the complete oriented frame. Input is 448 × 448; a luminance-guided filter refines its coarse boundary on a raster capped at 1536 px. The PNG is saved in the project and uses the shared subject correction and rendering path. Canceling, navigating, or switching tools invalidates the request before it can create an edit. Inference uses CPU/GPU locally; no photos are uploaded. The pinned model download is hash-verified by `scripts/prepare-sky-model.sh`, with attribution and license bundled under `Resources/ModelNotices`.
- `Retouch.swift`, `EditorStore+Retouch.swift`, `RetouchEditingLayer.swift`, and `RetouchPanel.swift`: photo-specific heal and clone strokes. Clone translates a sampled patch; heal retains its detail while matching low-frequency color to the destination. Both use soft brush coverage in original-image coordinates and render before geometry and global adjustments.
- `WhiteBalanceEyedropper.swift` and `WhiteBalancePickingLayer.swift`: translate a click through crop, rotation, and EXIF orientation to the RAW decoder's native neutral point. The decoder returns Kelvin and tint values, which are saved as ordinary RAW settings and remain compatible with the existing sliders, presets, and export path.
- `RawSettings.swift`: the settings that belong to the RAW decode (white balance, noise reduction, sharpness, detail, lens corrections), what the engine reports for a file, and white balance presets. Changing one re-decodes (about half a second on a 24 MP S5 file); every value is optional, so an untouched photo stores nothing.
- `ColorGrading.swift`: the tone curve (monotone cubic through user points, per-channel) and HSL (eight bands blended smoothly, baked into a 48-point color cube that is cached). Both act on gamma-encoded color and are skipped when untouched so highlights keep their headroom.
- `AdjustmentGroups.swift`: the Develop panel's groups, and everything built on them: presets, copy/paste/sync, history entries, and preset files.
- `EditorStore+Develop.swift`: RAW info, white balance actions, and the 100% view.
- `AutoAdjustmentAnalyzer.swift` and `EditorStore+Auto.swift`: a separate actor decodes an as-shot preview at 512 px, identifies consistent neutral-color evidence, and fits bounded tone suggestions through the existing renderer using 64 px samples. Tone follows the visible crop. RAW WB uses the decoder's camera calibration; other formats use warmth/tint. Auto replaces only basic light/WB controls as one named history step, keeps other edits, and rejects canceled or stale completions. Repeated Auto analyzes the same source baseline. Values save/export as ordinary adjustments in schema 10.
- `EditorStore+Presets.swift`: applying presets to a selection as one undo step, user preset management, copy/paste/sync, history, and preset import/export.
- `FocusLoupeView.swift`, `ToneCurveEditor.swift` (also the HSL panel), and `PresetPanel.swift` (also the save-preset and copy-settings sheets).
- `IngestService.swift`: card-to-shoot copy. Streams each file to `name.partial` while hashing it, flushes, reads it back without the file cache, compares, then renames into place. Skips a file already present (same name, size, and timestamp, or same content), gives a different file with a colliding name a `-1` suffix, and mirrors to an optional backup. The card is only read.
- `EditorStore+Ingest.swift`: shoot folder layout, remembered locations, and the import flow that fills the project as files arrive.
- `EditorStore+Culling.swift`: capture-ordered visible photos, filters, selection, rating/flag/label commands, key handling, remove, Delete Rejected, and autosave.
- `CullingModels.swift`: flag, color label, filter, and the Lightroom key map.
- `CullPreviewCache.swift`: six screen-sized previews kept around the current photo; at most two decodes in flight, with stale queued work replaced on navigation. RAW files use the camera's embedded JPEG (about 15 ms each).
- `CullWorkspace.swift` and `ImportSheet.swift`: the loupe, compare view, filmstrip, filter bar, and import dialog.
- `ThumbnailCache.swift`: stable, adjustment-aware JPEG thumbnails in Application Support and one 32 MiB LRU memory budget shared by photo/video thumbnails. The store publishes completion revisions instead of retaining duplicate image dictionaries.
- `UserPresetRepository.swift`: persistent user presets backed by app preferences.
- `VideoMediaService.swift`: AVFoundation metadata and poster-frame extraction.
- `AudioWaveformService.swift`: asynchronous PCM peak extraction with stable memory and Application Support disk caches.
- `TimelineCompositionService.swift`: translates persistent V1/A1 clip metadata into a playable AVMutableComposition and reports recoverable media warnings.
- `VideoWorkspace.swift`: source viewer, media bin, inspector, and persistent V1/A1 timeline controls.
- `AgentModels.swift`, `AgentEngine.swift`, and `AgentWorkspace.swift`: local-first workflow agents with reviewable findings and reversible adjustment proposals.
- `scripts/agent-review.sh`: deterministic developer reviewers for workflow, renderer, schema, compatibility, and release checks.

Photo geometry is stored as optional normalized crop data for backward-compatible `.pmedit` loading. Preview zoom and pan are view state, while crop, straighten, and adjustment history remain non-destructive project edits.

## Autosave

A project that has a file on disk saves itself 1.5 seconds after each change, and immediately before New, Open, or Quit. Only a project that has never been saved asks whether to save.

Save errors persist separately from general status messages until a successful retry, Save As, or project replacement. New/Open and Quit are gated while a card import is running. Each import owns an operation identity and project generation; replacement invalidates queued callbacks, and a subsequent import waits for a cancelled copy worker to finish cleanup. The final verified-file result is reconciled before autosave. Reference-file imports retain their originating generation too.

## Project format

The first project format is readable JSON with the `.pmedit` extension. It stores absolute reference-file URLs. Missing originals can be relinked without changing asset identity or losing adjustments. Every format revision increments `schemaVersion`; newer unsupported versions fail explicitly.

Schema 7 adds healing/clone strokes, schema 8 subject masks, schema 9 subject edge refinement, and schema 10 sky masks. Schema 8 subject masks decode with neutral edges. The integration candidate retains schema 10 and the existing persisted representation; it adds no schema. Older projects remain readable, while applications supporting an earlier schema cannot open newly saved schema-10 projects. The app bundle declares `com.perceptionmedia.project` as a JSON-compatible `.pmedit` type. Test on a project copy when comparing with an older build.

Preview thumbnails are disposable cache files, not project data. Their keys include the asset identity, source path, source modification date, and adjustment metadata, so stale renders are not reused.

## Video playback boundary

V0.3 stores non-destructive `TimelineClip` records separately from source media. Per-clip entries in `videoAdjustmentsByClipID` reuse `PhotoAdjustments`, so the same light, color, presence, and preset values persist for photos and timeline clips. `TimelineCompositionService` translates clip records into an `AVMutableComposition` and attaches a Core Image-backed `AVVideoComposition` whenever a clip has color adjustments. The store owns playback state, playhead synchronization, and automatic active-clip selection; missing or incompatible clips are skipped with visible warnings.

Per-clip entries in `audioAdjustmentsByClipID` persist volume, pan intent, fade-in, and fade-out without modifying source media. Timeline playback applies volume and fade ramps through `AVAudioMix`. Pan is reserved in the model but intentionally deferred until a custom audio-processing tap can implement it accurately. Waveform peaks are extracted at a reduced mono sample rate, normalized for display, and cached by source path, modification date, and sample count.

The current sequence uses the first playable clip's preferred transform. The color render layer deliberately excludes photo crop and rotation metadata; per-clip mixed-orientation fitting remains future work.

## Memory management

Photo rendering uses half-float linear working sources to preserve RAW highlight headroom.
Core Image allocation targets are 256 MB for editing, 128 MB for focus/export, and 32 MB for thumbnails. These are targets rather than process-wide caps. Synchronous
render operations drain autoreleased intermediates before returning. Closing 100% focus,
completing or failing an export, and replacing the project clear expendable context caches.
A macOS memory-pressure observer drops thumbnail, culling, brush, and decoded selection/subject-preview caches, trims the working
source cache, and clears renderer resources while preserving the visible image and project.

Auto uses one UI control beneath the histogram and the advanced tone/WB analyzer. Its task is owned by the store, cancellation is checked before analysis and between fitting passes, and completion checks operation identity, project generation/ID, source URL, and the initial edit snapshot. Undo/redo, manual edits, navigation, and tool changes cancel pending Auto. Analysis uses a 128 MB Core Image allocation target and clears render caches when finished; this is not a whole-process memory cap.

Culling cancellation is cooperative: a RAW decode already inside a synchronous system call
keeps its concurrency slot until it returns. Cancelled and removed requests cannot repopulate
the cache. A failed decode is not automatically retried forever. Compare and neighborhood
requests are submitted together so the comparison image is not cancelled by prefetching.

Use `scripts/profile-memory.sh` for an isolated real-RAW footprint/latency/pixel comparison.
Set `PME_RAW_SAMPLE_DIR` to a folder of at least four RW2 files. Measurements include compressed
and graphics memory charged to the process; they are not a whole-app memory ceiling.
