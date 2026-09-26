# Architecture

Perception Media Editor is a native Apple Silicon macOS app built with SwiftUI and AppKit, Core Image for photo rendering, and AVFoundation for the planned video engine.

## Core rule

Original media is never modified. A `.pmedit` project stores references to the originals plus adjustment metadata. Preview and export reconstruct the result from those instructions.

## V0.1 modules

- `EditorModels.swift`: versioned project, media, adjustments, crop, and preset data.
- `ProjectDocument.swift`: atomic JSON project persistence and schema guard.
- `PhotoRenderer.swift`: GPU-backed Core Image render and export pipeline.
- `EditorStore.swift`: main-actor application state and file-panel workflows.
- Workspace views: Library, Photo, Video placeholder, and Export.

## Project format

The first project format is readable JSON with the `.pmedit` extension. It stores absolute reference-file URLs. Media relinking and a package-based cache arrive in V0.2. Every format revision increments `schemaVersion`; newer unsupported versions fail explicitly.

## Planned video boundary

The video engine will translate timeline metadata into `AVMutableComposition`, `AVVideoComposition`, and `AVAudioMix` objects. It will reuse `PhotoAdjustments` as the starting point for a shared photo/video color model.
