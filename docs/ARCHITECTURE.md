# Architecture

Perception Media Editor is a native Apple Silicon macOS app built with SwiftUI and AppKit, Core Image for photo rendering, and AVFoundation for the planned video engine.

## Core rule

Original media is never modified. A `.pmedit` project stores references to the originals plus adjustment metadata. Preview and export reconstruct the result from those instructions.

## Current modules

- `EditorModels.swift`: versioned project, media, adjustments, crop, and preset data.
- `ProjectDocument.swift`: atomic JSON project persistence and schema guard.
- `PhotoRenderer.swift`: GPU-backed Core Image render and export pipeline.
- `EditorStore.swift`: main-actor application state and file-panel workflows.
- Workspace views: Library, Photo, Video placeholder, and Export.
- `HistogramView.swift`: accessible RGB histogram rendered from the edited image pipeline.
- `PhotoComparisonView.swift`: original, edited, split, and side-by-side presentation modes.
- `ThumbnailCache.swift`: stable, adjustment-aware JPEG thumbnails in Application Support.
- `UserPresetRepository.swift`: persistent user presets backed by app preferences.
- `VideoMediaService.swift`: AVFoundation metadata and poster-frame extraction.
- `TimelineCompositionService.swift`: translates persistent V1/A1 clip metadata into a playable AVMutableComposition and reports recoverable media warnings.
- `VideoWorkspace.swift`: source viewer, media bin, inspector, and persistent V1/A1 timeline controls.

## Project format

The first project format is readable JSON with the `.pmedit` extension. It stores absolute reference-file URLs. Missing originals can be relinked without changing asset identity or losing adjustments. Every format revision increments `schemaVersion`; newer unsupported versions fail explicitly.

Preview thumbnails are disposable cache files, not project data. Their keys include the asset identity, source path, source modification date, and adjustment metadata, so stale renders are not reused.

## Video playback boundary

V0.3 stores non-destructive `TimelineClip` records separately from source media. `TimelineCompositionService` translates those records into an `AVMutableComposition` whenever the sequence changes. The store owns playback state, playhead synchronization, and automatic active-clip selection; missing or incompatible clips are skipped with visible warnings.

The current sequence uses the first playable clip's preferred transform. Per-clip mixed-orientation fitting belongs in the future `AVVideoComposition` color/render layer. That layer will also reuse `PhotoAdjustments` as the starting point for a shared photo/video color model.
