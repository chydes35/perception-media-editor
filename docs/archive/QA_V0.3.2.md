# QA Report — V0.3.2 Timeline Playback

## Release candidate

- **Build:** Perception Media Editor 0.3.2 (5)
- **Platform:** macOS 15, Apple Silicon
- **Scope:** V0.3 sequence playback, editing-state synchronization, missing-media recovery, and photo-workspace regression coverage
- **Fixtures:** two H.264/AAC MP4 clips at 1280 × 720 (3 seconds and 2 seconds), one PNG photo, and a saved two-clip `.pmedit` project

## Result

**Proceed for internal use / next milestone.** No blocker, critical, or major defects were found. Fourteen checks passed and one minor usability defect remains. Three broader compatibility and performance areas are deferred because they require a larger fixture matrix.

| Result | Count |
| --- | ---: |
| Pass | 14 |
| Minor defect | 1 |
| Blocked | 0 |
| Not tested | 3 |

## Acceptance and regression matrix

| Area | Check | Result | Evidence |
| --- | --- | --- | --- |
| Project | Open a saved two-clip project | Pass | Both referenced clips and the five-second sequence loaded. |
| Timeline playback | Present one sequence transport in timeline mode | Pass | Native AVKit controls are suppressed; the custom transport remains. |
| Source playback | Preserve native source-preview controls | Pass | AVKit controls and **Preview Timeline** appear in source mode. |
| Sequence playback | Play across a clip boundary | Pass | Playback crossed the three-second cut and updated the active clip. |
| Playhead | Show time inside the V1/A1 tracks | Pass | The in-track playhead moved across both linked tracks. |
| Selection | Keep V1/A1 clip selection linked | Pass | Selecting either representation selected the matching clip pair. |
| Reorder controls | Disable impossible edge moves | Pass | Earlier is disabled for the first clip and later for the last clip. |
| Trimming | Increase source in-point while paused | Pass | Sequence duration changed from five to four seconds and the composition rebuilt. |
| Reordering | Reorder clips without changing duration | Pass | Clip order changed while the four-second sequence duration remained stable. |
| Muting | Toggle selected-clip audio state | Pass | Mute/unmute rebuilt playback and restored the original state. |
| Missing media | Open a project with one source unavailable | Pass | The project stayed usable, skipped the unavailable source, and displayed an inline warning. |
| Media recovery | Restore a missing source and rebuild | Pass | The full five-second composition returned and the warning cleared. |
| Photo regression | Import and edit a still image | Pass | Photo workspace, histogram, adjustments, and presets loaded normally. |
| Persistence | Decode existing project data | Pass | Model checks and the saved fixture confirmed backward-compatible loading. |
| Selection after edit | Keep the moved clip selected after reorder | Minor defect | Selection follows the clip under the paused playhead instead of the clip just moved. |

## Defect

### Minor — Reordering can change the selected clip while paused

**Reproduction**

1. Pause the timeline with the playhead positioned over a clip other than the selected clip.
2. Move the selected clip earlier or later.
3. Observe the selection after the composition rebuild.

**Observed:** Active-clip synchronization selects the clip under the unchanged playhead position.

**Expected:** The clip just moved remains selected so the user can continue editing it.

**Impact:** Sequence order, duration, and playback are correct, but the user may need to reselect the moved clip before another edit.

**Workaround:** Select the moved clip again.

## Accessibility and design verification

- Source and timeline playback modes expose distinct, non-competing transports.
- Compact icon controls have accessible names and hover help.
- Impossible reorder actions expose disabled states.
- Track identity is communicated by labels and icons in addition to color.
- Long inspector values use middle truncation and expose the full value as hover help.
- Missing-media status is available as text rather than color alone.

## Deferred coverage and residual risk

- Mixed-orientation and per-clip transform behavior across a sequence was not exercised; composition framing still follows the first playable clip.
- Long-form and high-clip-count playback performance was not profiled.
- A broad codec, frame-rate, color-space, HDR, and audio-layout compatibility matrix was not run.

## Handoff

The build is suitable for the next internal milestone. The minor selection issue should enter the next production pass, while mixed-orientation framing and performance remain explicit release-hardening risks. With no blocker or major defects, the next gate is cross-functional release review before broader distribution.
