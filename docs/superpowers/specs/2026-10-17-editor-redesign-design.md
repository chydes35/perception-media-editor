# Editor redesign: Photo and Video shells, and a split video editor

Date: 2026-10-17. Status: draft for the owner's review. Written from a conversation with the owner, with mockups shown in a browser (kept in `.superpowers/brainstorm/` in the session that made them, not in this repository).

## Intent

The editor should feel like a modern pro tool, not a prototype: bigger buttons and a more modern, technical look across the whole app (the owner's words), and a layout built around how the owner actually works.

The owner is a photographer and videographer (Lumix S5, iPhone 15 Pro) making photo shoots, and video for brands and commercials. Today the app has six flat tabs (Library, Cull, Photo, Video, Export, Agents) and one video screen that does cutting, color and audio at once. The owner wants two clear categories, Photo and Video, each with its own steps, and a video editor with separate Cut, Color and Audio screens.

Their video workflow, in their words: trim each clip to length, grade it, add songs and fix audio, verify, export. For commercial and brand work, pick a song first and cut the video around its beat. For audio: make sure it does not clip, and adjust gain. Later: 32-bit float audio files. For now 24-bit is enough.

## Decisions the owner made

- **Two categories along the top: Photo and Video.** Mode switch, large buttons.
- **A tall left rail of large buttons** holds the steps for the current category ("option B" in the mockups). Each step is a separate screen.
- **Photo steps: Import, Cull, Develop, Export.** The owner said "that's good" to keeping Photo as it is today, in the new shell.
- **Video steps: Import, Cut, Color, Audio, Export.**
- **Import and Export belong to their category.** Photo Import and Export offer what suits photos; Video's offer what suits video (for example ProRes 422 HQ and HEVC Main10 export).
- **The look follows the Mac's light and dark setting.** Both appearances must look right; the mockups happened to be dark.
- **Browsing the photo library lives under the Import step** (the owner confirmed this).
- **Agents stays, and is reachable from both Photo and Video**, as a smaller button in the top bar.
- **Color screen:** viewer in the middle with before/after. Under it, switchable waveform, RGB parade, histogram and vectorscope. On the right: source color (ACES, a LUT, or as recorded), curves with RGB and per-channel tabs, and light, color and HSL controls. The owner approved the mockup.
- **Cut screen:** media bin, viewer and clip inspector on top; timeline below. The song sits on the timeline with its waveform and beat markers, and clip edges snap to beats. Tools: select, trim, split, ripple delete, a snap-to-beats toggle and a beat-grid choice. The owner approved the mockup.
- **Audio screen:** L/R level meters with a clip light, master gain, a count of clipped spots with a jump-to-next button, a gain control per clip, and clipping marked red on the waveforms. 24-bit now. The owner approved the mockup.
- **Order of work:** (1) the new shell and look, with Photo moved in unchanged; (2) the Video split into Cut, Color and Audio; (3) beat detection and snapping on the Cut timeline.

## Goals

- Every screen is reachable in two clicks: category, then step.
- Large, easy targets throughout. A crisp, modern, "technical" look that is consistent across Photo and Video.
- The Color screen shows live scopes and curves while the owner grades, including on clips that play through the compositor.
- The Audio screen makes clipping impossible to miss and gain easy to fix.
- Cutting to a song's beat is fast.

## Non-goals

- No changes to what the photo tools do. Photo moves into the new shell as it is.
- No new color science. The V-Log and Apple Log pipeline, LUTs, ACES and the compositor stay as they are.
- No EQ, compressors, noise reduction or audio effects.
- No transitions, titles or speed changes (already outside the current milestone).
- 32-bit float audio is not built now.

## Anti-goals

- A redesign that breaks existing projects (`.pmedit`) or loses edits. Old projects must open and look the same inside.
- A redesign that makes the app slower or heavier on the 8 GB M1: scopes and waveforms must keep their current limits (scopes off the main actor, bounded memory).
- Fake controls: nothing in a screen should look usable if it does nothing.

## Constraints

- Target machine: 8 GB M1 MacBook Air, Command Line Tools only (no Xcode). Tests run with the SDK workaround in `docs/TESTING_STRATEGY.md`.
- Originals are never written. Projects are non-destructive; any model change bumps the schema with a tested migration (`docs/DATA_MODEL.md`).
- The photo and video color contract is shared (`PhotoAdjustments`). The Color screen reuses it.
- Existing pieces to reuse, not rebuild:
  - Scopes: `ScopeRenderer`, `ScopeTap`, `ScopeModel` (waveform, RGB parade, vectorscope); the panel exists today on the Video screen behind a toggle.
  - The histogram (`HistogramView`) and the tone-curve editor (`ToneCurveEditor`) exist for photos and should be reused for video clips.
  - The source-color picker and LUT import (`LUTControls.swift`).
  - Audio waveforms (`AudioWaveformService`); clip audio adjustments (`ClipAudioAdjustments`: volume, pan, fades).
  - The timeline model and export (`TimelineExporter`).
- Follow `AGENTS.md`: an ExecPlan for the work, docs updated in the same change, and PASS/FAIL/NOT VERIFIED reporting. In-app behavior must be checked by walking through the running app, not inferred from tests.

## What exists today (facts the builder will need)

- `Workspace` has six cases: library, cull, photo, video, export, agents. `RootView` shows a segmented picker for them, with a global Import button and a global Export button (which exports the selected photo) in the top bar.
- The Video screen (`VideoWorkspace.swift`, about 780 lines) holds the bin, viewer, inspector, timeline and an optional scopes panel together.
- Clip volume is clamped to 0…1 in `TimelineCompositionService`, so today gain can only reduce a clip, not raise it.

## My calls (the owner should check these)

- **Top bar.** Photo | Video on the left, the project name and save state in the middle, an Agents button and the app status on the right. The global Import and Export buttons leave the top bar; each step's own screen carries them.
- **Size and style.** Minimum rail button height 56 pt and top-bar button height 36 pt; one accent gradient (teal to blue) for the selected state. These come from the mockups; the exact values are the builder's to tune, in both light and dark.
- **Audio "gain".** Gain is in dB, can exceed 0 dB (boost) as well as cut, and is a separate control from the existing fades. The existing volume model (0…1) will need extending, with a schema bump.
- **Beat detection.** Beats come from analyzing the song (on-device, off the main actor), shown as markers; the owner can nudge the grid. The method is the builder's choice.

## Left to the builder

- The exact SwiftUI structure and view state for the rail and mode switch, and how existing views migrate into it.
- The beat-detection algorithm and its accuracy bar, within the constraints above.
- How gain above 0 dB is applied (AVAudioMix limits, or processing the audio ourselves).
- Detailed spacing, typography, icons and the light and dark palettes.
- Whether the rail remembers the last step per category (suggested).

## Verification the owner expects

For each part, a walk-through in the running app on the target Mac with real clips, reported as PASS/FAIL/NOT VERIFIED:
- Part 1: both categories and all rail steps reachable; an old project opens; Photo behaves as before.
- Part 2: scopes, histogram and curves update live on a V-Log clip in Color; clipping is flagged in Audio on a clip that clips; Cut still trims, splits and exports frame-exactly.
- Part 3: beat markers line up with an audible beat on a real song; clips snap to them.
