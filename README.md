# Perception Media Editor

A native, non-destructive macOS photo and video editor built specifically for Perception Media's documentary, interview, business, social, and photography workflows.

This repository currently contains **V0.3: Video Editor Foundation (in progress)**.

## What works now

- Import JPEG, HEIC, PNG, TIFF, and Core Image-supported RAW files by reference
- Browse imported photos in a native library
- Adjust exposure, contrast, highlights, shadows, temperature, tint, vibrance, saturation, sharpness, and vignette
- Rotate and apply common social/photo aspect ratios
- Apply four built-in Perception presets
- Save and delete reusable user presets
- Inspect a live RGB histogram
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

The current machine has mismatched Command Line Tools and SDK versions, so the verification script pins the compatible local SDK, runs model/persistence checks against the real source files, and compiles the complete app. With full Xcode installed, these checks will migrate to the standard Swift Testing target.

## Build a local app bundle

```sh
chmod +x scripts/build-app.sh
./scripts/build-app.sh
open PerceptionEditor.app
```

The script produces an ad-hoc signed `PerceptionEditor.app` for local use. A full Xcode installation is recommended before the project adds asset catalogs, Instruments profiling, notarization, and AVFoundation timeline work.

## Project status

See [docs/ROADMAP.md](docs/ROADMAP.md) and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
