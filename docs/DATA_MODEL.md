# Project data contract

`EditorProject` and related records in `Sources/PerceptionEditor/EditorModels.swift` are the source of truth for the versioned `.pmedit` JSON document. `ProjectDocument.swift` handles atomic persistence and rejects unsupported newer schema versions. `EditorStore+Project.swift` owns save state and recovery actions.

## Stable identities

- Media entries refer to original file URLs. Relinking changes the reference while preserving asset identity and edit metadata.
- Photo adjustments, crops, masks, ratings, flags, labels, and timeline data are non-destructive project metadata.
- Timeline clips refer to source media and carry their own trim, ordering, color, and audio adjustment records. Photo and clip color share `PhotoAdjustments` where intended.
- Preset files and user preferences have their own persistence boundaries; they are not original media.

The integrated candidate uses schema **10**, preserving the advanced branch's representation. Healing/clone strokes, subject/sky grayscale PNGs, edge refinement, and brush corrections remain photo-specific edit metadata. Preset/copy/sync groups transfer gradients while retaining each target photo's raster selections, repairs, and geometry. Older schema 6–9 files remain readable; a save advances them to 10. Applications supporting earlier schemas reject schema-10 projects.

The schema version is defined in code. Check it before changing fields; do not assume an app bundle version and project schema version advance together. For a schema change, specify defaults, old-file loading, round-trip behavior, unsupported newer-file handling, and relink behavior in the ExecPlan.

Thumbnails, waveforms, preview rasters, and brush rasters are disposable caches. Cache eviction must never remove edits or user source files. Undo/history is session state unless a feature explicitly changes that contract.

## Studio OS transfer queue

`StudioOSTransfers.json` is separate from `.pmedit` projects and is not part of them. **`.pmedit` schema 10 is unchanged.**

- Location: `~/Library/Application Support/PerceptionMediaEditor/StudioOSTransfers.json`, replaced atomically on every change.
- Format: `{ "version": 1, "transfers": [TransferRecord] }`.
- `TransferRecord`: `id` (the client transfer id), `serverURL`, `webURL`, `galleryID`, `bookingID`, `destinationLabel`, `createdAt`, `jpegQuality`, `longEdgePixels`, `protectedOriginalPaths`, `stagingFolderPath`, `remoteTransferID`, `status` (running, paused, cancelled, completed), `pausedReason`, `items`.
- `TransferItemRecord`: `id`, `position`, `sourcePath`, `adjustments` (a snapshot taken when Send was pressed), `displayName`, `uploadFileName`, `stagedPath`, `sizeBytes`, `sha256`, `remoteItemID`, `mediaID`, `putStarted`, `phase` (queued, rendered, processing, ready, failed), `message`.
- The file contains no credentials and no signed URLs. Upload URLs are requested when needed and never stored.
- A file that cannot be decoded is moved aside as `StudioOSTransfers.json.corrupt-<timestamp>`, the queue starts empty, and the panel shows a warning. It is never deleted.

Other Studio OS state:

- Keychain generic password, service `com.perceptionmedia.editor.studio-os`, account `device-token`: the device token.
- `UserDefaults`: `studioOS.serverURL`, `studioOS.webURL`, `studioOS.stagingFolder`, `studioOS.lastDestinationGalleryID` (a suggestion only).

See [ARCHITECTURE.md](ARCHITECTURE.md) for component ownership and [TESTING_STRATEGY.md](TESTING_STRATEGY.md) for compatibility gates.
