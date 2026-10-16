# Project data contract

`EditorProject` and related records in `Sources/PerceptionEditor/EditorModels.swift` are the source of truth for the versioned `.pmedit` JSON document. `ProjectDocument.swift` handles atomic persistence and rejects unsupported newer schema versions. `EditorStore+Project.swift` owns save state and recovery actions.

## Stable identities

- Media entries refer to original file URLs. Relinking changes the reference while preserving asset identity and edit metadata.
- Photo adjustments, crops, masks, ratings, flags, labels, and timeline data are non-destructive project metadata.
- Timeline clips refer to source media and carry their own trim, ordering, color, and audio adjustment records. Since schema 11, clip timing is whole frames: `frameRate`, `sourceStartFrame` and `durationFrames` in the source's rate, and `timelineStartFrame` in the sequence rate (the first clip's). Video `MediaAsset`s record `frameRate`, `frameCount` and `sourceColor`. `sourceColor` is a `SourceColorDescriptor`: bit depth, chroma, range and matrix from the format description, and transfer and gamut from the camera's metadata when it has any. Lumix files tag V-Log as BT.709, but their `com.panasonic.Semi-Pro.metadata.xml` item says `CaptureGamma` V-Log. `EditorProject.colorInputByAssetID` holds a per-media-item `ColorInputTransform` (`automatic` when absent). All three are read on import and backfilled when an older project opens. Schema ≤ 10 clips keep their seconds in `legacyTiming` until the source has been read, then convert exactly; offline clips save their original seconds unchanged. See [decisions/2026-10-16-frame-exact-timing.md](decisions/2026-10-16-frame-exact-timing.md). Photo and clip color share `PhotoAdjustments` where intended.
- Preset files and user preferences have their own persistence boundaries; they are not original media.

Branch `plan/10bit-vlog-color` moves to schema **11** (frame-exact clip timing, above); older builds reject schema-11 files. The integrated candidate uses schema **10**, preserving the advanced branch's representation. Healing/clone strokes, subject/sky grayscale PNGs, edge refinement, and brush corrections remain photo-specific edit metadata. Preset/copy/sync groups transfer gradients while retaining each target photo's raster selections, repairs, and geometry. Older schema 6–9 files remain readable; a save advances them to 10. Applications supporting earlier schemas reject schema-10 projects.

The schema version is defined in code. Check it before changing fields; do not assume an app bundle version and project schema version advance together. For a schema change, specify defaults, old-file loading, round-trip behavior, unsupported newer-file handling, and relink behavior in the ExecPlan.

Thumbnails, waveforms, preview rasters, brush rasters, and video proxies (content-keyed, see [decisions/2026-10-15-video-proxies.md](decisions/2026-10-15-video-proxies.md)) are disposable caches. Proxy keys carry a format version (`ProxyFingerprint.formatVersion`, now 2), so a generator fix regenerates proxies instead of reusing wrong ones; version-1 files are orphaned, not deleted. Cache eviction must never remove edits or user source files. Undo/history is session state unless a feature explicitly changes that contract.

See [ARCHITECTURE.md](ARCHITECTURE.md) for component ownership and [TESTING_STRATEGY.md](TESTING_STRATEGY.md) for compatibility gates.
