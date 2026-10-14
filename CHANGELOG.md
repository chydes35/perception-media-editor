# Changelog

Newest first. Pull request numbers refer to `chydes35/perception-media-editor`.

## Unreleased

- White balance edits keep one RAW filter per photo, so exact renders take about 100-120 ms instead of 330 ms and up, including the first one after opening a photo (see [metal-canvas](plans/active/metal-canvas.md)).
- Photo canvas drawn by a Metal view through Core Image (step 1 of [metal-canvas](plans/active/metal-canvas.md)); `PME_SystemImageCanvas=1` restores the SwiftUI image.
- Integrated photo tools, reliability safeguards, and batch JPEG delivery (#7): subject and sky masks (Vision and a CoreML sky model), advanced Auto tone and white balance, white balance eyedropper, schema 10, save recovery, bounded undo and caches, memory-pressure cleanup, sequential batch JPEG export, preview lifecycle fixes.
- Known issue: the edited canvas can stay black after Export → New → Open → Photo (see [CURRENT_STATUS](docs/CURRENT_STATUS.md)).
- Docs: dated QA and review reports moved to `docs/archive/`; `CURRENT_STATUS.md` rewritten as a one-screen summary.

## 2026-09-27

- Non-destructive heal and clone tools (#6).
- Continuous wheel zoom in the photo editor (#5).

## 2026-09-26

- Gradient and brush masks (#4).
- RAW develop, tone curve, HSL, presets, and history (#3).
- Import from card, culling, and shoot folders (#2).
- Background photo rendering, bounded memory, and safety fixes (#1).
- Photography workflow agents.

## 2026-09-25

- Video foundation: timeline composition playback, clip color adjustments, cached waveforms and fades.
- V0.2 production photo workflow start.
- V0.1 photo engine: Core Image pipeline, presets, histogram, `.pmedit` projects, JPEG/PNG export.
