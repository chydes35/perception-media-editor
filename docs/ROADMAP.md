# Perception Media Editor Roadmap

## Direction (decided 2026-09-26)

The goal is a full Lightroom replacement for a single photographer's workflow. Photo comes first and must be complete before video work resumes. Typical job: 100–200 Lumix S5 RW2 files per session, edited on an 8 GB M1 MacBook Air, so every feature has a memory budget. Existing Lightroom edits are not migrated; new shoots start fresh. Masks, healing, and presets are used on nearly every shoot.

### Phase 0 — Foundation (in progress)

- [x] Swift Testing suite that runs with Command Line Tools or Xcode
- [x] Off-main-thread preview, histogram, thumbnail, and export rendering
- [x] Memory-bounded working copies (2560 px, four cached) and metadata-only import
- [x] Presets, look matching, and batch edits keep each photo's crop and rotation
- [x] Photo dimensions recorded on import and backfilled for older projects
- [x] Unsaved-changes prompt on New, Open, and Quit
- [x] `\` before/after toggle that never fires while typing
- [x] Crop editor shows the whole frame while editing an existing crop
- [ ] GitHub Actions build
- [ ] Split photo, timeline, and project responsibilities out of `EditorStore`

### Phase 1 — Library and culling

- Session-per-shoot projects, SD card import with copy, rename, and optional backup
- Flags, stars, color labels, filters, and removing photos
- Keyboard culling: full-screen loupe, P/X/1–5, instant next image, compare view

### Phase 2 — RAW develop and presets

- `CIRAWFilter` controls: Kelvin white balance from as-shot, highlight recovery, noise reduction, lens correction
- Tone curve, HSL, color grading, auto-tone
- Preset library, copy/paste/sync settings, history, snapshots, virtual copies

### Phase 3 — Masks and healing

- Linear, radial, and brush masks; Vision subject and sky masks
- Spot healing and clone

### Phase 4 — Delivery

- Batch export recipes: size, quality, output sharpening, sRGB/P3, naming, copyright/IPTC, watermark

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

## V0.3 — Video Editor (current)

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

- Subject masking with Vision
- Keyframes and tracking
- Multicam synchronization and angle editor
- Optical-flow speed changes
