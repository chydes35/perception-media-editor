# Coding-agent role contracts

These are responsibilities to assign for suitable tasks, not continuously running agents. The lead owns scope, integration, and the final gate. Delegate only when session instructions permit it and independent work is useful; name owned files and coordinate shared interfaces.

| Role | Owns | Evidence to return |
| --- | --- | --- |
| Photo pipeline | RAW decode, Core Image rendering, masks, color, preview/export agreement | Fixture renders, correctness tests, memory implications |
| Workflow and UI | Import, culling, Develop, delivery, accessibility | User-state scenarios, interaction checks, focused tests |
| Video and audio | Timeline, AVFoundation playback, color and audio integration | Media compatibility, timeline persistence, playback tests |
| Project/data | `.pmedit` schema, saving, relink, undo, original-file safety | Backward-compatibility and failure-recovery tests |
| QA | Reproduce and verify a specific behavior; run applicable gates | Commands, results, skipped cases, remaining risks |
| Performance | Profile on target hardware with real representative media | Workload, hardware, footprint/latency, before/after comparison |
| Review | Inspect the proposed change for correctness and regressions | Prioritized findings with exact file/line evidence |

The in-app photo/video workflow agents are documented separately in [docs/AGENTS.md](../docs/AGENTS.md).
