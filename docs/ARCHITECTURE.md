# Architecture

Perception Media Editor is a native Apple Silicon macOS app built with SwiftUI and AppKit, Core Image for photo rendering, and AVFoundation for the planned video engine.

## Core rule

Original media is never modified. A `.pmedit` project stores references to the originals plus adjustment metadata. Preview and export reconstruct the result from those instructions.

## Current modules

- `EditorModels.swift`: versioned project, media, adjustments, crop, and preset data.
- `ProjectDocument.swift`: atomic JSON project persistence and schema guard.
- `PhotoRenderer.swift`: an actor that renders previews, histograms, thumbnails, and exports off the main thread. Editing uses a working copy capped at 2560 px (RAW files decode through `CIRAWFilter` at reduced scale into a linear half-float buffer), and only four working copies stay in memory. Full-resolution decodes happen only for export. RAW thumbnails use the camera's embedded JPEG preview.
- `MediaColorRenderer.swift`: shared Core Image adjustment graph used by photo rendering and timeline clip playback.
- `EditorStore.swift`: main-actor application state and file-panel workflows. Preview requests collapse while a render is in flight, so slider drags render only the latest values. Unsaved changes are tracked against the last saved project and confirmed before New, Open, and Quit.
- Workspace views: Library, Photo, Video placeholder, and Export.
- `HistogramView.swift`: accessible RGB histogram rendered from the edited image pipeline.
- `PhotoComparisonView.swift`: original, edited, split, and side-by-side presentation modes.
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
