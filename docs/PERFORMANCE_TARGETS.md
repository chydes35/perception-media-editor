# Performance targets and measurement

The target workload is a 100–200-file Lumix S5 RW2 shoot on an 8 GB M1 MacBook Air. Smooth culling and responsive editing matter more than maximizing concurrent decodes. A target is not a measured pass.

## Existing engineering constraints

- Editing working copies are capped at 2560 px and four cached sources; full-resolution work is reserved for 100% focus and export.
- Culling decode concurrency is bounded, stale queued work is replaced, and thumbnail memory has a shared budget.
- Core Image allocation targets and undo/history budgets limit individual owners; they do not cap the whole process. Full-resolution focus/export normally use 128 MiB, with a lazy 256 MiB context for active healing because the observed 24 MP RAW color-matching render needs more than 128 MiB. That context is released at operation/cache lifecycle boundaries.
- Real-RAW memory evidence and limitations are recorded in [MEMORY_PROFILE_2026-09-28.md](archive/MEMORY_PROFILE_2026-09-28.md) and [MEMORY_OPTIMIZATION_2026-09-28.md](archive/MEMORY_OPTIMIZATION_2026-09-28.md).

## Video proxies

| Operation | Target | Measured |
|---|---|---|
| Proxy generation, S5 UHD 4:2:2 H.264 | ≥ 1.2× realtime (28.8 fps at 23.976) | 71.4 fps (about 3.0×), 10 s trim, debug build |
| Proxy decode (ProRes 422 Proxy, 1080p) | ≥ 120 fps | 345 fps (evaluation probe) |

UI responsiveness during generation is NOT VERIFIED.

## Acceptance workload

Run a distinct 100–200-photo shoot through import, culling, Develop, masks, focus, export, save/reopen, and cache release on the target Mac. Record hardware and OS, sample count, file sizes, cold/warm cull latency, slider/mask response, first focus decode, export time, peak process footprint, and footprint after leaving focus/export. Check output pixels and failure recovery. `scripts/profile-memory.sh` is an isolated renderer diagnostic, not a full SwiftUI app measurement.

Do not invent a pass/fail number from one isolated sample. Before a feature milestone claims performance completion, set a measured threshold for its specific operation and compare a baseline with the candidate build under the same workload. Report **NOT VERIFIED** when the representative media or interactive test is unavailable.

The [October 7 target-Mac validation](archive/WORKFLOW_VALIDATION_2026-10-07.md) records a 100-distinct-S5-photo varied-library displayed run and a separate fresh-process renderer diagnostic. It does not substitute for the genuine single-shoot workload, broad visual acceptance, or an agreed threshold/baseline comparison.
