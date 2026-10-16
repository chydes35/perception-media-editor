# Video proxies are a content-keyed disposable cache

Date: 2026-10-15
Status: accepted

## Context
Lumix S5 10-bit 4:2:2 H.264 UHD has no hardware decode on the target 8 GB M1. AVFoundation software decode reaches 45 fps (1.9× realtime) and drops to 12 fps if frames are requested as BGRA. Scrubbing, reverse play, and overlapping clips need more headroom than that.

## Decision
- Generate ProRes 422 Proxy (≤1920×1080, video only) with AVAssetReader → AVAssetWriter. Measured on a 10 s trim of a real S5 clip (debug build): 68.5 fps (about 2.9× realtime) to make at `.utility` QoS (71.4 fps at `.userInitiated`), 345 fps to play. Generation runs at `.utility`, and a 1 s watchdog ends a job whose writer or reader fails while the sample loop is idle.
- Key proxies by content (size + first/last MiB, SHA-256), not by path or asset ID, in `Proxy Cache` under Application Support. The `perceptionEditor.proxyDirectory` default overrides the location.
- Keep proxies out of `.pmedit` (schema stays 10). Preview resolves proxies; `MediaQuality.export` (for video export, not built yet) always resolves originals; audio is never proxied, so the source viewer plays proxy video with the original's audio.
- One job at a time, timeline clips first. The blocking AVFoundation sample loops run on a dedicated serial dispatch queue per job, not on Swift's cooperative pool (parallel test runs hung there).
- Clearing the cache deletes only store-owned files (64-hex `.mov` and `.partial.mov`), because the proxy folder is user-configurable.

## Consequences
- About 16 GB of disk per hour of footage at 1080p. Generation is refused below estimate + 2 GiB free.
- Clearing the cache never loses edits and costs only regeneration time. A proxy deleted mid-session is noticed the next time it is enqueued, shown in the source viewer, or used by a timeline rebuild; it is regenerated, and playback uses the original until then.
- Preview sharpening/vignette radii are computed at proxy resolution and can differ slightly from export.
- A proxy finishing in the background never takes over the viewer; it rebuilds the timeline only when already in timeline mode.

## Amendment 2026-10-16: full-range sources

The S5 records V-Log in **full range**, tagged BT.709. Reading such a source as video-range `x422` makes AVFoundation add 64 to luma without rescaling. The proxy then stored original + 64, tagged video range, so AVPlayer and Core Image showed it about 17% brighter than the original (grey 0.392 → 0.460) and clipped above original code 876. Reading the same source as `xf22` was bit-exact with ffmpeg. The reader's scaled `x422` path also clipped at 940.

- Full-range sources are read as `xf22`, scaled to proxy size by the reader. `VTPixelTransferSession`, whose range scaling is correct, converts them to video-range `x422`, and the frames are appended through a pixel-buffer adaptor. Video-range sources are unchanged.
- `ProxyFingerprint.formatVersion` is 2, so existing proxies regenerate. Version-1 files are orphaned in the cache folder until "remove all proxies".
- Evidence: a full-range HEVC 4:2:2 fixture proxy matches its original within 4/1023 RGB (146 levels off before). Real `P1107158.MOV` cell means are within 1.8/1023 (104.5 before). Generation on the 10 s UHD trim runs at 72.0 fps debug and 79.6 fps release.

## Amendment 2026-10-16: frame timestamps

The generator wrote proxies at AVAssetWriter's default timescale of 600. Frame times such as 1001/24000 s (25.025 ticks) were rounded to a whole tick, so a proxy frame started up to 0.4 ms off its original's start (234 of 240 frames in a test). A player asking for a frame's exact time then showed the frame before it, which a frame-numbered composition test caught as a one-frame lag on proxied clips. The writer and its video input now use the source track's own timescale (24000 for the S5), so every proxy frame starts exactly when its original did. `ProxyFingerprint.formatVersion` is 3, so existing proxies regenerate.

