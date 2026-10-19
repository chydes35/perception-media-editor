# Perception Media Editor Roadmap

## Direction (decided 2026-09-26)

The goal is a full Lightroom replacement for a single photographer's workflow. Photo comes first and must be complete before video work resumes. Typical job: 100–200 Lumix S5 RW2 files per session, edited on an 8 GB M1 MacBook Air, so every feature has a memory budget. Existing Lightroom edits are not migrated; new shoots start fresh. Masks, healing, and presets are used on nearly every shoot.

### Phase 0 — Foundation (complete, PR #1)

- [x] Swift Testing suite that runs with Command Line Tools or Xcode
- [x] Off-main-thread preview, histogram, thumbnail, and export rendering
- [x] Memory-bounded working copies (2560 px, four cached) and metadata-only import
- [x] Presets, look matching, and batch edits keep each photo's crop and rotation
- [x] Photo dimensions recorded on import and backfilled for older projects
- [x] Unsaved-changes prompt on New, Open, and Quit
- [x] `\` before/after toggle that never fires while typing
- [x] Crop editor shows the whole frame while editing an existing crop
- [x] GitHub Actions build
- [ ] Split photo, timeline, and project responsibilities out of `EditorStore` (carried into Phase 2; culling and ingest live in `EditorStore+Culling.swift` and `EditorStore+Ingest.swift`)

#### Reliability follow-up — 2026-09-28

- [x] Protect all referenced originals during export and publish completed outputs atomically
- [x] Bind import callbacks to an operation/project generation; cancel scanning and drain old copy workers safely
- [x] Reconcile all verified imports before the final project save
- [x] Persist save-failure status with Retry Save and Save As recovery
- [x] Store undo changes for affected photos with shared undo/redo and shoot-wide history retention budgets
- [x] Separate deterministic brush-cache checks from isolated timing benchmarks
- [ ] Complete a real 100–200-distinct-photo UI workflow and combined process-memory profile

See [Reliability Pass](archive/RELIABILITY_PASS_2026-09-28.md) for verification evidence and remaining acceptance work.

#### Memory follow-up — 2026-09-28

- [x] Release autoreleased rendering intermediates and clear focus/export/project-replacement caches
- [x] Tune editing, thumbnail, focus and export context allocation targets on the 8 GiB M1 Mac
- [x] Share one bounded thumbnail cache and make disk keys deterministic
- [x] Bound culling decodes, replace stale queued work and prevent late cache repopulation
- [x] Reclaim expendable caches on macOS memory pressure
- [x] Add isolated RAM/latency/output-equivalence profiling with real RAW samples

See [Memory Optimization](archive/MEMORY_OPTIMIZATION_2026-09-28.md) for measurements and remaining whole-app acceptance work.

#### Local integration — 2026-10-07

The [integration plan](../plans/completed/photo-workflow-integration.md) combines GitHub main, the advanced local photo tools, and the preserved reliability/memory/batch-delivery work on `codex/photo-workflow-integration`. The candidate retains project schema 10. Automated integration checks do not close the open UI, image-quality, or 100–200-photo performance gates. The [target-Mac validation](archive/WORKFLOW_VALIDATION_2026-10-07.md) adds displayed evidence from 100 distinct S5 photos across dated library folders and records the healing allocation defect/correction; genuine single-shoot, broad visual, and threshold-based acceptance remain open.

### Phase 1 — Library and culling (complete, PR #2)

- [x] One folder per shoot: `<Shoots>/<date> <Name>/{Name.pmedit, Originals/}`, saved automatically
- [x] Import from card: verified copy (SHA-256 read back from disk), never modifies the card, skips files already imported, optional backup drive that is skipped safely when disconnected
- [x] Camera filenames kept; capture time read from EXIF and used for ordering
- [x] Flags (P/X/U), stars (0–5), color labels (6–9), filters, multi-select, remove from project
- [x] Cull view: instant next/previous from a preview cache, compare (C), full screen (F), auto-advance, Develop (D)
- [x] Delete Rejected moves originals inside the shoot's Originals folder to the Trash (recoverable) after confirmation
- [ ] RAW+JPEG pairs treated as one photo
- [x] Zoom to 100% for focus checks (delivered in Phase 2)
- [ ] Undo for rating, flag, and label changes

### Phase 2 — RAW develop and presets (in progress)

- [x] RAW engine controls: white balance in Kelvin and tint (as-shot by default, Lightroom-style presets), luminance and color noise reduction, sharpness, detail, lens corrections
- [x] Highlight headroom kept through the decode so exposure and highlights recover blown areas
- [x] Zoom to 100% (Z, button, or click) in Develop and Cull, pan in about 12 ms
- [x] Tone curve: RGB plus R, G, B point curves with presets
- [x] HSL: hue, saturation, luminance for eight color bands
- [x] Presets by group (Light, Color, Presence, Tone Curve, HSL, RAW Detail, White Balance), organized in categories, renamed, moved, updated, imported, and exported (`.pmpreset`)
- [x] Apply a preset to the whole selection as one undo step
- [x] Copy Settings (⇧⌘C), Paste Settings (⇧⌘V), Sync Settings
- [x] History: named steps for the current photo; click one to go back
- [x] White balance eyedropper for RAW photos (click a neutral gray to set Kelvin and tint)
- [ ] RAW highlight roll-off: highlights above white fade smoothly instead of clipping, and Highlights recovers them. Merged with its tests; the photographer's visual check of the final look is pending ([plan](../plans/active/raw-highlight-rolloff.md))
- [x] Auto tone and auto white balance: one button beneath the histogram; bounded on-device analysis, photo-specific basic slider values, conservative neutral-reference WB, one undo step
- [ ] Per-scene look matching (Agents → Look Matching): group a shoot into lighting scenes, find each scene's edited hero, adapt its look to every other photo's exposure and white balance, flag low-confidence matches, apply the selected ones as one undo step. Implemented on branch `look-match-lm1`; the real family-portrait shoot check is pending ([LM1 plan](../plans/active/look-match-agent.md))
- [ ] Split `EditorStore` into photo, timeline, and project parts

### Phase 3 — Masks and healing (in progress)

- [x] Linear and radial gradient masks: drag on the photo to place them, drag handles to move and resize, rotation and feather in the panel
- [x] Brush and erase: soft feathered strokes, ⌥ to erase, [ and ] to resize, each stroke one undo step
- [x] Adjustments inside a mask: exposure, contrast, highlights, shadows, warmth, tint, saturation, sharpness; per-mask amount, invert, hide, duplicate, delete
- [x] Masks stay on the same part of the picture through rotation, straighten, and crop
- [x] Red mask overlay (O), shown automatically while dragging or painting
- [x] Gradient masks sync, copy, and save into presets; brush strokes stay with their photo
- [x] First subject-selection pass: Vision person and foreground instances, click or list selection, soft saved mask, brush correction, and local adjustments
- [x] Subject refinement controls: candidate hover previews, edge shift, feather, contrast, reset, and a consistent all-subject union
- [ ] Subject-selection quality validation across hair, translucent details, groups, and mixed RAW cameras (two-person JPEG and synthetic soft-edge checks covered; broader real-photo fixtures still needed)
- [x] First sky-selection pass: bundled Core ML semantic segmentation, guided edge refinement, saved mask, Add/Remove spill brushes, and local adjustments
- [ ] Sky-selection quality validation across sunsets, overcast scenes, foliage, fine structures, reflections, and mixed RAW cameras
- [ ] Color and luminance range masks
- [x] Spot healing and clone: paint soft repairs, adjust source points, and retain edits through crop, rotation, save, and export

The [October 8 real-RAW selection pass](archive/SELECTION_QUALITY_2026-10-08.md) records missing group candidates and missed sky gaps through fine branches. These quality gates remain open despite structural mask/export checks passing.

### Phase 4 — Delivery (in progress)

- [x] Sequential selected-photo JPEG export with quality, long-edge size, collision-safe naming, progress/cancel, and per-file results
- [ ] Batch export recipes: persistent presets, output sharpening, P3, copyright/IPTC, watermark
- [ ] Real 100–200-photo delivery pass and whole-app export memory profile

### Phase 5 — Smart culling

- Vision sharpness, closed-eye, and near-duplicate scoring

Video (V0.3 below) resumes after the photo phases. Lumix S5 10-bit 4:2:2 and V-Log footage will likely need proxies and LUT support.

## V0.1 — Photo Engine (complete)

- [x] Native SwiftUI macOS shell
- [x] Non-destructive project model
- [x] Reference-file photo import
- [x] Core Image preview pipeline
- [x] Light, color, sharpness, vignette, rotation, and aspect controls
- [x] Built-in Perception presets
- [x] Original/edited comparison
- [x] Full-resolution JPEG/PNG export
- [x] Save and reopen `.pmedit` project files
- [ ] Interactive crop and straighten (moved to V0.2)
- [x] Histogram
- [x] User-created presets

## V0.2 — Production Photo Workflow (backlog remains)

- [ ] RAW-specific development controls and metadata panel
- [ ] Batch selection, adjustment sync, and batch export
- [ ] LUT import and intensity control
- [x] Persistent thumbnail cache and media relinking
- [x] Before/after split and side-by-side views
- [x] Interactive crop and straighten with preview zoom and pan
- [x] Grouped photo edit undo and redo with direct adjustment values
- [ ] Export presets, resize, watermark, and metadata controls

## V0.3 — Video Editor (existing baseline; development deferred)

- [x] AVFoundation video import, thumbnails, metadata, and playback
- [x] Persistent V1/A1 timeline model and interface
- [x] Clip trim, split, reorder, mute, play, and ripple delete controls
- [x] AVMutableComposition sequence playback, scrubbing, and active-clip sync
- [x] Shared color model for photos and video clips
- [x] Waveform cache, clip volume, and fades
- [ ] Clip pan and advanced audio mixing
- [ ] Titles, basic transitions, speed presets, and frame capture
- [ ] 1080p and 4K export

## V1.0 — Perception Workflow

- Documentary, interview, social reel, business promo, and photography templates
- Proxy generation and original-media export
- Reusable Perception title, color, audio, and export presets
- Batch deliverables and project launcher with recent projects
- Performance, accessibility, recovery, and release hardening

## Later

- Local generative remove/fill: deferred until the core photo editor is complete. The initial M1/PyTorch inpainting trial hit its five-minute limit at step 5 of 20 and increased system swap substantially; see [local trial notes](archive/LOCAL_GENERATIVE_REMOVE_TRIAL.md).
- Keyframes and tracking
- Multicam synchronization and angle editor
- Optical-flow speed changes
