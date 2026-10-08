# Project data contract

`EditorProject` and related records in `Sources/PerceptionEditor/EditorModels.swift` are the source of truth for the versioned `.pmedit` JSON document. `ProjectDocument.swift` handles atomic persistence and rejects unsupported newer schema versions. `EditorStore+Project.swift` owns save state and recovery actions.

## Stable identities

- Media entries refer to original file URLs. Relinking changes the reference while preserving asset identity and edit metadata.
- Photo adjustments, crops, masks, ratings, flags, labels, and timeline data are non-destructive project metadata.
- Timeline clips refer to source media and carry their own trim, ordering, color, and audio adjustment records. Photo and clip color share `PhotoAdjustments` where intended.
- Preset files and user preferences have their own persistence boundaries; they are not original media.

The current schema version is defined in code. Check it before changing fields; do not assume an app bundle version and project schema version advance together. For a schema change, specify defaults, old-file loading, round-trip behavior, unsupported newer-file handling, and relink behavior in the ExecPlan.

Thumbnails, waveforms, preview rasters, and brush rasters are disposable caches. Cache eviction must never remove edits or user source files. Undo/history is session state unless a feature explicitly changes that contract.

See [ARCHITECTURE.md](ARCHITECTURE.md) for component ownership and [TESTING_STRATEGY.md](TESTING_STRATEGY.md) for compatibility gates.
