# Perception Media Editor

A native, non-destructive macOS photo and video editor built specifically for Perception Media's documentary, interview, business, social, and photography workflows.

This repository currently contains **V0.3: Video Editor Foundation (in progress)**.

## What works now

- Import from a camera card into a dated shoot folder with verified copies and an optional backup drive
- Cull with Lightroom's keys (P/X/U, 0–5, 6–9, arrows), compare two photos, filter by flag, stars, and label
- Import JPEG, HEIC, PNG, TIFF, and Core Image-supported RAW files by reference
- Browse imported photos in a native library
- Adjust exposure, contrast, highlights, shadows, warmth, tint, vibrance, saturation, sharpness, and vignette
- Develop RAW files with white balance in Kelvin, noise reduction, sharpness, detail, and lens corrections; edit tone curves and HSL; check focus at 100%
- Local adjustments with linear and radial gradients, brush masks, Vision subject selection, and on-device Core ML sky selection. Hover over a detected subject or its name to preview it before selecting. Refine subject and sky masks with Edge shift (negative shrinks, positive expands), Edge feather, Edge contrast, and painted Add/Remove spill corrections. Each mask has its own exposure, contrast, highlights, shadows, warmth, tint, saturation, and sharpness
- Continuous mouse-wheel zoom over the photo while editing masks or crops; press the wheel or hold Command and drag to pan, or click Fit to reset
- Save presets by settings group, organize them in categories, apply them to a whole selection, copy and paste settings between photos, and step back through an edit history
- Rotate and apply common social/photo aspect ratios
- Apply four built-in Perception presets
- Save and delete reusable user presets
- Inspect a live RGB histogram
- Click **Auto** beneath the histogram for photo-specific exposure, contrast, highlights, shadows, white balance, and tint suggestions. Fine-tune the sliders afterward; Auto is one undo step and runs entirely on this Mac
- Compare original and edited photos in original, edited, split, and side-by-side modes
- Cache thumbnails on disk and relink missing originals
- Save and reopen non-destructive `.pmedit` project files
- Export edited full-resolution JPEG or PNG files in sRGB
- Import MOV/MP4 video with duration, frame-size metadata, and poster thumbnails
- Preview source video through AVFoundation
- Build a persistent V1/A1 sequence with trim, split, reorder, mute, play, and ripple-delete controls
- Preview the edited timeline as one AVMutableComposition with playhead scrubbing and active-clip sync
- Rebuild timeline playback after edits while preserving the paused or playing state
- Skip missing or incompatible media with visible playback warnings
- Apply the same non-destructive color model and Perception presets to individual timeline clips
- View cached audio waveforms and set non-destructive per-clip volume, fade-in, and fade-out automation
- Run local-first workflow agents for culling, look matching, batch editing, photo/video quality, delivery, metadata, relinking, and project health
- Run deterministic developer reviewers from `scripts/agent-review.sh`

## Run for development

Requirements: Apple Silicon Mac, macOS 15 or newer, and Swift 6.1 or newer.

```sh
swift run PerceptionEditor
```

## Test

```sh
chmod +x scripts/test.sh
./scripts/test.sh
```

The script runs the Swift Testing suite in `Tests/PerceptionEditorTests` and then builds the app. It works with full Xcode or with only Command Line Tools; with Command Line Tools it adds the flags SwiftPM needs to find the Swift Testing framework.

## Build a local app bundle

```sh
chmod +x scripts/build-app.sh
./scripts/build-app.sh
open PerceptionEditor.app
```

The script produces an ad-hoc signed `PerceptionEditor.app` for local use. Full Xcode is recommended for Instruments profiling.

The first build downloads and verifies Apple's Apache-licensed DETR semantic segmentation model, then compiles and bundles it for sky selection. Subsequent builds reuse the cache. Photo analysis runs entirely on the Mac without network access. Set `PERCEPTION_BUILD_DIR` and `PERCEPTION_SKY_MODEL_DIR` to keep build and model caches on another drive.

## Project status

See [docs/ROADMAP.md](docs/ROADMAP.md) and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
