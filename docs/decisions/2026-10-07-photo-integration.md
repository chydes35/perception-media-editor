# Photo workflow integration — October 7, 2026

The external checkout's reliability/memory/batch-delivery work was preserved in snapshot commit `c0f10e5`, then GitHub main at `0350a4c` and the advanced local branch at `5e574f9` were merged on `codex/photo-workflow-integration`. The original source branches and second worktree remain available.

Use the advanced Auto analyzer: it fits tones through the shared rendering graph, considers the visible crop, and supports conservative camera-calibrated RAW white balance. Remove the older Auto Tone implementation and duplicate button; retain the menu shortcut. Combine it with a cancellable store-owned task and project-generation/source/snapshot checks. Test the asynchronous path using an injectable analysis closure.

Retain schema 10 without a new persisted representation. Keep subject/sky masks and repair strokes with each photo during sync/preset operations. Extend existing undo/history cost accounting to cover their raster bytes and points. Preserve original-file protection, atomic export, operation-bound ingest, save recovery, cache budgets, and the declared project content type. Increment the candidate bundle build to 16.

This is a local integration decision, not release certification. Broad selection quality, whole-app footprint, 100–200-photo delivery, macOS 15 CI for the combined candidate, and a fresh installed-app check remain separate gates. The full roadmap still prioritizes photo work before video or generative removal.
