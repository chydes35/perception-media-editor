# Design Review — V0.3.1 Timeline Playback

## Review basis

The timeline must make source selection, sequence playback, clip state, trimming, ordering, muting, and recoverable media problems understandable in a native macOS editing workflow. The review covered empty, populated, playing, paused, selected-clip, and missing-media states at the app's default size.

## Overall assessment

The three-pane editor and two-track timeline establish a clear professional editing structure. The strongest choice is the linked V1/A1 selection: one clip identity is consistently represented across both tracks, the viewer, and the inspector.

## Findings

### High — Competing playback controls

**Evidence:** Timeline mode presents AVKit's full transport inside the viewer and a second custom playhead transport directly below it.

**Impact:** Two play buttons and two scrubbers create uncertainty about which control owns sequence state, especially after an edit rebuild.

**Correction:** Keep AVKit controls for source preview, suppress them for timeline preview, and make the custom timeline transport the single sequence control.

### High — Timeline lacks an in-track playhead

**Evidence:** Playback time is visible in the viewer transport, but the V1/A1 tracks do not show where that time falls across clip boundaries.

**Impact:** Users cannot connect the current frame to a precise clip position or anticipate the next cut from the timeline itself.

**Correction:** Draw a high-contrast vertical playhead across both tracks using the same duration-to-width mapping as the clips.

### Medium — Redundant timeline action

**Evidence:** “Preview Timeline” remains visible while the viewer is already labeled TIMELINE.

**Impact:** The button appears to promise a state change but simply seeks the active composition.

**Correction:** Show the action only while previewing a source and only when the timeline contains clips.

### Medium — Sequence-edge actions appear available

**Evidence:** Move-left and move-right controls remain enabled when the selected clip is already at that edge.

**Impact:** Clicking produces no visible result, which makes the command feel broken.

**Correction:** Disable impossible moves and add explanatory tooltips to compact icon controls.

### Medium — Inspector values clip without recovery

**Evidence:** Long media names are truncated in the narrow inspector value column.

**Impact:** Similar filenames become difficult to distinguish.

**Correction:** Use middle truncation and expose the full value as hover help.

## Preserve unchanged

- Three-pane media/viewer/inspector hierarchy
- Orange V1 and blue A1 track language
- White linked-selection outline across V1/A1
- Inline missing-media warning treatment
- Source-versus-timeline mode badge

## Revision sequence and re-review criteria

1. Establish one transport per playback mode.
2. Add the in-track playhead.
3. Clarify conditional and boundary actions.
4. Confirm long metadata remains discoverable.
5. Re-review source mode, timeline mode, playing across a cut, paused editing, and missing media.
