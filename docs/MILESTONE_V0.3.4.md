# V0.3.4 Milestone — Waveforms and Clip Audio Mix

## Build contract

This increment begins the V0.3 audio roadmap with visible waveform context and non-destructive clip-level mix automation. It preserves the existing timeline model, linked V1/A1 selection, mute behavior, sequence playback, and reference-file project format.

## Delivered

- Persistent `ClipAudioAdjustments` for volume, pan intent, fade-in, and fade-out
- Project schema 4 with schema 1–3 decoding compatibility
- Asynchronous mono PCM peak extraction for video and audio sources
- Memory and Application Support waveform caching keyed by source modification state
- Trim-aware waveform display inside A1 timeline clips
- Per-clip volume, fade-in, fade-out, and reset controls
- Timeline playback volume automation through `AVAudioMix`
- Split behavior that keeps the original fade-in on the first segment and original fade-out on the second
- Cleanup of clip audio records on ripple delete
- V0.3.4 build 7 metadata and documentation

## Acceptance checklist

| Requirement | Status |
| --- | --- |
| Existing projects open with neutral audio defaults | Verified by model migration checks |
| Audio adjustments survive save and reopen | Passed: 23% volume, 0.5s fade-in, and 0.7s fade-out reloaded on the adjusted clip |
| Waveforms load without blocking project open | Passed: both two-tone fixtures rendered 160-sample A1 waveforms asynchronously |
| Waveform cache is reused when source state is unchanged | Passed: two cache files remained unchanged through project reopen |
| Volume affects only the selected clip | Passed: the adjusted first clip retained 23% while the second clip remained at 100% |
| Fade-in and fade-out automate the selected clip | Passed: AVAudioMix playback crossed the cut with the adjusted ramp configuration active |
| Mute remains authoritative | Passed: existing mute path continues to omit the clip's audio insertion before mix automation |
| Split and delete keep audio metadata coherent | Model behavior implemented; interaction review required |
| Debug and signed production builds pass | Passed for V0.3.4 build 7 |

## Intentional boundary

True per-clip pan requires channel-aware sample processing through an audio-processing tap. The schema reserves `pan` now, but the control and playback processing are deferred to the next audio increment rather than shipping an inaccurate balance approximation.

## Review instructions

1. Open a two-clip sequence with audible sources.
2. Confirm the A1 clips display waveforms.
3. Set the first clip to 25% volume and add short fade-in and fade-out values.
4. Play across the cut and confirm the second clip retains its neutral mix.
5. Save and reopen the project to confirm the selected clip's values persist.
6. Split an adjusted clip and confirm fades stay at the sequence edges rather than appearing at the split.

The implementation should proceed to design review, then focused QA of audible ramps, cache reuse, persistence, mute interaction, and waveform behavior for silent or audio-less sources.
