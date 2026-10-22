# Coding standards

## Swift and ownership

Use Swift 6.1-compatible code for a macOS 15 target. Keep UI state on `@MainActor`; run decode, render, file copy, hashing, and waveform work outside UI event handling. Make actor crossings and cancellation explicit. Keep one owner for project state, save state, and each cache; avoid duplicate image retention in view models.

Extend existing focused types before adding new managers. `EditorStore` is a UI facade; keep domain work in services or cohesive extensions, and extract responsibilities incrementally. Preserve public interfaces across photo, video, and project code unless the plan names every caller and migration.

## Media and project data

Original media is read-only. Import copies are verified before becoming project assets. Exports check every referenced original as a protected destination and publish complete outputs atomically. Tests that write files use disposable fixtures.

Persist edits as metadata in `.pmedit`; do not bake edits into originals. Keep decode/default values distinct from explicit user edits. A schema change increments `schemaVersion`, documents migration behavior, and tests old files. Missing references retain asset identity and adjustments through relink.

Use the shared color pipeline where photo and video behavior intentionally matches. State any quality difference between fast previews, 100% focus, and exports. Cache keys must include the source and edit inputs needed to prevent stale results.

## Concurrency

Blocking AVAssetReader or file work must not run on `Task.detached` or the cooperative pool (it starves unrelated async work and hung the full suite once); use a utility `DispatchQueue` plus a continuation. Heavy work stays off the main actor.

## Tests and documentation

Test behavior at boundaries: disk failure, cancellation, collision, old project data, missing media, and preview/export agreement. Prefer deterministic correctness checks to timing assertions in the regular suite. Put isolated benchmarks in scripts or opt-in tests and label their hardware and workload.

Update the relevant architecture or roadmap documentation when behavior changes. Avoid claiming a feature complete based only on a source reviewer, a synthetic fixture, or a build.
