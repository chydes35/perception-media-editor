# Architecture

Perception Media Editor is a native Apple Silicon macOS app built with SwiftUI and AppKit, Core Image for photo rendering, and AVFoundation for the planned video engine.

## Core rule

Original media is never modified. A `.pmedit` project stores references to the originals plus adjustment metadata. Preview and export reconstruct the result from those instructions.

## Current modules

- `EditorModels.swift`: versioned project, media, adjustments, crop, and preset data.
- `ProjectDocument.swift`: atomic JSON project persistence and schema guard.
- `PhotoRenderer.swift`: GPU-backed Core Image render and export pipeline.
- `MediaColorRenderer.swift`: shared Core Image adjustment graph used by photo rendering and timeline clip playback.
- `EditorStore.swift`: main-actor application state and file-panel workflows.
- Workspace views: Library, Photo, Video placeholder, and Export.
- `HistogramView.swift`: accessible RGB histogram rendered from the edited image pipeline.
- `PhotoComparisonView.swift`: original, edited, split, and side-by-side presentation modes.
- `ThumbnailCache.swift`: stable, adjustment-aware JPEG thumbnails in Application Support.
- `UserPresetRepository.swift`: persistent user presets backed by app preferences.
- `VideoMediaService.swift`: AVFoundation metadata and poster-frame extraction.
- `AudioWaveformService.swift`: asynchronous PCM peak extraction with stable memory and Application Support disk caches.
- `TimelineCompositionService.swift`: translates persistent V1/A1 clip metadata into a playable AVMutableComposition and reports recoverable media warnings.
- `VideoWorkspace.swift`: source viewer, media bin, inspector, and persistent V1/A1 timeline controls.
- `AgentModels.swift`, `AgentEngine.swift`, and `AgentWorkspace.swift`: local-first workflow agents with reviewable findings and reversible adjustment proposals.
- `scripts/agent-review.sh`: deterministic developer reviewers for workflow, renderer, schema, compatibility, and release checks.

## Project format

The first project format is readable JSON with the `.pmedit` extension. It stores absolute reference-file URLs. Missing originals can be relinked without changing asset identity or losing adjustments. Every format revision increments `schemaVersion`; newer unsupported versions fail explicitly.

Preview thumbnails are disposable cache files, not project data. Their keys include the asset identity, source path, source modification date, and adjustment metadata, so stale renders are not reused.

## Video playback boundary

V0.3 stores non-destructive `TimelineClip` records separately from source media. Per-clip entries in `videoAdjustmentsByClipID` reuse `PhotoAdjustments`, so the same light, color, presence, and preset values persist for photos and timeline clips. `TimelineCompositionService` translates clip records into an `AVMutableComposition` and attaches a Core Image-backed `AVVideoComposition` whenever a clip has color adjustments. The store owns playback state, playhead synchronization, and automatic active-clip selection; missing or incompatible clips are skipped with visible warnings.

Per-clip entries in `audioAdjustmentsByClipID` persist volume, pan intent, fade-in, and fade-out without modifying source media. Timeline playback applies volume and fade ramps through `AVAudioMix`. Pan is reserved in the model but intentionally deferred until a custom audio-processing tap can implement it accurately. Waveform peaks are extracted at a reduced mono sample rate, normalized for display, and cached by source path, modification date, and sample count.

The current sequence uses the first playable clip's preferred transform. The color render layer deliberately excludes photo crop and rotation metadata; per-clip mixed-orientation fitting remains future work.
