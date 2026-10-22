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
