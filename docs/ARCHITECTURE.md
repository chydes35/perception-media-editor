# Architecture

Perception Media Editor is a native Apple Silicon macOS app built with SwiftUI and AppKit, Core Image for photo rendering, and AVFoundation for the planned video engine.

## Core rule

Original media is never modified. A `.pmedit` project stores references to the originals plus adjustment metadata. Preview and export reconstruct the result from those instructions.

## Current modules

- `EditorModels.swift`: versioned project, media, adjustments, crop, and preset data.
- `ProjectDocument.swift`: atomic JSON project persistence and schema guard.
- `PhotoRenderer.swift`: an actor that renders previews (working copies in GPU-shared half-float pixel buffers, one edited RAW variant per photo, one full-resolution buffer for the 100% view), histograms, thumbnails, and exports off the main thread. Editing uses a working copy capped at 2560 px (RAW files decode through `CIRAWFilter` at reduced scale into a linear half-float buffer), and only four working copies stay in memory. Full-resolution decodes happen only for export. RAW thumbnails use the camera's embedded JPEG preview.
- `MediaColorRenderer.swift`: shared Core Image adjustment graph used by photo rendering and timeline clip playback.
- `EditorStore.swift`: main-actor application state and file-panel workflows. Preview requests collapse while a render is in flight, so slider drags render only the latest values. Unsaved changes are tracked against the last saved project and confirmed before New, Open, and Quit.
- Workspace views: Library, Photo, Video placeholder, and Export.
- `HistogramView.swift`: accessible RGB histogram rendered from the edited image pipeline.
- `PhotoComparisonView.swift`: original, edited, split, and side-by-side presentation modes.
- `LocalMasks.swift`: the mask model (linear, radial, and brush shapes, each with its own adjustments) and the renderers that turn a mask into a grayscale image. Gradients are procedural and eased in linear light. Brush strokes are painted as soft dabs (lightest-wins for painting, darkest-wins for erasing) and cached, and painting continues from the previous raster so a stroke costs a few milliseconds however many strokes exist. Masks are stored in the original photo's coordinates.
- `ImageGeometry.swift`: maps positions between the original photo and the finished picture (rotation, straighten, crop), sharing its crop math with `MediaColorRenderer`. Verified against real renders, since the mask handles and the pixels must agree.
- `EditorStore+Masks.swift`, `MaskEditingLayer.swift`, and `MaskPanel.swift`: mask creation and editing, the handles and brush cursor drawn over the photo, and the panel.
- `Retouch.swift`, `EditorStore+Retouch.swift`, `RetouchEditingLayer.swift`, and `RetouchPanel.swift`: photo-specific heal and clone strokes. Clone translates a sampled patch; heal retains its detail while matching low-frequency color to the destination. Both use soft brush coverage in original-image coordinates and render before geometry and global adjustments.
- `RawSettings.swift`: the settings that belong to the RAW decode (white balance, noise reduction, sharpness, detail, lens corrections), what the engine reports for a file, and white balance presets. Changing one re-decodes (about half a second on a 24 MP S5 file); every value is optional, so an untouched photo stores nothing.
- `ColorGrading.swift`: the tone curve (monotone cubic through user points, per-channel) and HSL (eight bands blended smoothly, baked into a 48-point color cube that is cached). Both act on gamma-encoded color and are skipped when untouched so highlights keep their headroom.
- `AdjustmentGroups.swift`: the Develop panel's groups, and everything built on them: presets, copy/paste/sync, history entries, and preset files.
- `EditorStore+Develop.swift`: RAW info, white balance actions, and the 100% view.
- `EditorStore+Presets.swift`: applying presets to a selection as one undo step, user preset management, copy/paste/sync, history, and preset import/export.
- `FocusLoupeView.swift`, `ToneCurveEditor.swift` (also the HSL panel), and `PresetPanel.swift` (also the save-preset and copy-settings sheets).
- `IngestService.swift`: card-to-shoot copy. Streams each file to `name.partial` while hashing it, flushes, reads it back without the file cache, compares, then renames into place. Skips a file already present (same name, size, and timestamp, or same content), gives a different file with a colliding name a `-1` suffix, and mirrors to an optional backup. The card is only read.
- `EditorStore+Ingest.swift`: shoot folder layout, remembered locations, and the import flow that fills the project as files arrive.
- `EditorStore+Culling.swift`: capture-ordered visible photos, filters, selection, rating/flag/label commands, key handling, remove, Delete Rejected, and autosave.
- `CullingModels.swift`: flag, color label, filter, and the Lightroom key map.
- `CullPreviewCache.swift`: ten screen-sized previews kept around the current photo. RAW files use the camera's embedded JPEG (about 15 ms each).
- `CullWorkspace.swift` and `ImportSheet.swift`: the loupe, compare view, filmstrip, filter bar, and import dialog.
- `ThumbnailCache.swift`: stable, adjustment-aware JPEG thumbnails in Application Support.
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

## Project format

The first project format is readable JSON with the `.pmedit` extension. It stores absolute reference-file URLs. Missing originals can be relinked without changing asset identity or losing adjustments. Every format revision increments `schemaVersion`; newer unsupported versions fail explicitly.

Preview thumbnails are disposable cache files, not project data. Their keys include the asset identity, source path, source modification date, and adjustment metadata, so stale renders are not reused.

## Video playback boundary

V0.3 stores non-destructive `TimelineClip` records separately from source media. Per-clip entries in `videoAdjustmentsByClipID` reuse `PhotoAdjustments`, so the same light, color, presence, and preset values persist for photos and timeline clips. `TimelineCompositionService` translates clip records into an `AVMutableComposition` and attaches a Core Image-backed `AVVideoComposition` whenever a clip has color adjustments. The store owns playback state, playhead synchronization, and automatic active-clip selection; missing or incompatible clips are skipped with visible warnings.

Per-clip entries in `audioAdjustmentsByClipID` persist volume, pan intent, fade-in, and fade-out without modifying source media. Timeline playback applies volume and fade ramps through `AVAudioMix`. Pan is reserved in the model but intentionally deferred until a custom audio-processing tap can implement it accurately. Waveform peaks are extracted at a reduced mono sample rate, normalized for display, and cached by source path, modification date, and sample count.

The current sequence uses the first playable clip's preferred transform. The color render layer deliberately excludes photo crop and rotation metadata; per-clip mixed-orientation fitting remains future work.
