# Subject refinement — build 13

Verified on Apple Silicon with macOS 26.6.2 and the Command Line Tools SDK 26.5.

## Coverage

- Edge shift contracts/expands coverage without moving the subject.
- Feather preserves image-border coverage and matches a larger export extent.
- Neutral settings retain partial transparency; contrast firms soft weights.
- All-subject union retains every candidate and its soft weights.
- Schema 8 subject masks load with neutral edges; refined masks and brush corrections round-trip through schema 9.
- Picker reopening restores the overview. Rapid hover changes show the latest candidate, and cancellation prevents a late overlay from returning. Previews add no edits.
- Existing Add/Remove modes retain the detected mask while painting corrections.
- A real two-person JPEG keeps both people separate and supports erasing/restoring a selected person. The original remains outside the repository.

## Results

- Subject checks with the real-photo fixture: 9 tests passed.
- Full suite: 228 tests in 38 suites passed with `--no-parallel`; the opt-in real subject test was run separately above.
- Concurrent full run: one existing brush timing assertion narrowly failed (2.06 seconds against 2 seconds). The exact test passed alone and in the serial full run, without changing its threshold.
- Picker regression: temporarily restoring the old cached-picker behavior made the overview test fail; restoring the fix made it pass.
- Release source reviewer and `git diff --check`: passed.
- Release build completed and the packaged app passed signature verification. Native UI checks confirmed separate person selection, all three edge sliders updating, and Reset edges returning them to zero. A separate demo project saved with schema 9.

## Remaining quality work

Real-photo validation still needs a wider set of fine hair, translucent fabric, overlapping objects, and RAW cameras. These controls refine an existing selection; they do not add a new segmentation model. The reported blanket/dress photo has not been supplied for reproduction.

Build 13 saves schema 9. Older builds reject this schema, so retain a project copy if testing alongside an older app.
