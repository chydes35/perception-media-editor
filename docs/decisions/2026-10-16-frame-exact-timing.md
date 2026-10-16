# Frame-exact clip timing (schema 11) — October 16, 2026

Plan: [video-10bit-color-pipeline.md](../../plans/active/video-10bit-color-pipeline.md), Task 1.

## Context

Up to schema 10, `TimelineClip` stored `timelineStartSeconds`, `sourceStartSeconds` and `durationSeconds` as `Double`. `TimelineCompositionService` converted them with `CMTime(seconds:preferredTimescale: 600)`. One 23.976 fps frame lasts 1001/24000 s, which is 25.025 ticks of 1/600 s, so every edit point was rounded. When a cut's source and timeline positions rounded in different directions, the cut started a fraction of a tick before the frame it meant, and the player showed the previous source frame. `TimelineFrameExactTests.shuffledCutsShowExactlyTheirFrames` shows this: **55 of 240 output frames were wrong** on the old code. That run used a correctly timed fixture in a separate worktree. Cuts whose source and timeline offsets are equal hide the problem, because both roundings cancel. Trims (±1 s) and splits (half of a Double duration) also produced cut points that were not on frame boundaries.

## Decision

- `TimelineClip` stores `frameRate` (the source's), `sourceStartFrame` and `durationFrames` in that rate, and `timelineStartFrame` in the project's sequence rate. The sequence rate is the first clip's rate (`EditorProject.sequenceFrameRate`). Every edit re-packs the timeline in it (`EditorProject.packTimeline`). Seconds are now read-only computed values for display.
- `FrameRate` holds an exact frame duration (`1001/24000`). Track durations within 0.05% of a camera rate snap to that rate, so a 3754/90000 container reads as 23.976. Frame↔`CMTime` conversions are exact integer arithmetic. Seconds convert to frames (ties to even) only at the edges: migration and the seconds-based ±1 s trim buttons.
- The composition sets the video and audio tracks' `naturalTimeScale` and the video composition's `frameDuration` to the sequence rate. It cuts from the track's first timestamp and keys color and audio segments by exact `CMTimeRange`s.
- Trims and splits move whole frames. The shortest clip is 6 frames. Seeking snaps to the nearest frame start.
- `MediaAsset` gains `frameRate` and `frameCount`, read on import, ingest and relink.
- **Migration:** a schema ≤ 10 clip decodes its seconds into `legacyTiming`, with provisional 23.976 frames. After open (`EditorStore.migrateClipTimingIfNeeded`) and after relink, the source's real rate is read and the clip converted exactly (`EditorProject.adoptFrameMetadata`). The saved snapshot is converted the same way, so this does not mark the project edited. A clip whose media is offline keeps and saves its original seconds until relink, so nothing is rounded twice.
- A clip at a different rate from the sequence fills whole sequence frames, its source is cut to that slot, and a warning is shown. Proper mixed-rate editing is out of scope.

## Alternatives considered

- **Keeping seconds but using timescale 24000:** this fixes 23.976 alone, but the stored Doubles still are not frames, and other rates would need their own timescale.
- **Storing `CMTime` values:** exact, but they don't express "a whole frame" and need custom coding. Frame counts are simpler to reason about and to test.
- **Converting during decode:** decoding is synchronous and does not know the source's rate. Assuming 23.976 would silently mis-convert 25p and 59.94p footage.

## Consequences

- Schema 11. Older app builds reject schema-11 projects through the existing `unsupportedSchema` guard. Schema 6–10 files open and are saved as 11.
- The test movie writers now use timescale 24000. At the writer default of 600 the fixture files themselves rounded frame times, so a frame test on those fixtures measures the fixture, not the code.

## Verification

`FrameTimeTests`, `ProjectMigration11Tests` (including an end-to-end open of a schema-10 project), and `TimelineFrameExactTests` (three cut layouts, every output frame decoded at zero tolerance) pass. The full suite passes: 392 tests, 0 failed (CLT wrapper, 2026-10-16).

**G6 on the composition:** `RealVideoFrameExactTests` with `PME_VIDEO_SAMPLE=P1107157.MOV` (33 240 frames) cuts source frames 33 000–33 239 to timeline 0. All 25 sampled frames best match their own source frame by PSNR, at ≥ 45 dB and ≥ 3 dB above the neighbors. Repeating G6 through an export needs Task 8. The old code was not run against this real-footage check.
