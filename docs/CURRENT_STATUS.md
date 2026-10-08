# Current development status

Updated: 2026-09-29. This is a worktree status map, not a release certification. The checkout contains uncommitted application and test changes from the reliability/memory work; preserve them when starting a new task.

## Product position

The photo-first roadmap is authoritative. Phase 0 foundation and Phase 1 library/culling are marked complete. Phase 2 RAW Develop/presets and Phase 3 masks/healing remain in progress. Delivery, smart culling, and resumed video work remain later phases. The legacy V0.x checklists in [ROADMAP.md](ROADMAP.md) contain some stale unchecked items; verify in code before using them to select work.

The app has verified card import, culling, RAW Develop controls, presets, non-destructive masks, single-photo JPEG/PNG export, a new batch JPEG queue, and an initial video timeline. The in-app local workflow agents are described in [AGENTS.md](AGENTS.md). The agentic **coding** workflow starts in the repository root [AGENTS.md](../AGENTS.md).

## Current evidence and open acceptance

- The September 28 [reliability pass](RELIABILITY_PASS_2026-09-28.md) recorded a 224-test execution pass and a local release build at that worktree state. It also records original protection, import ownership, save recovery, and bounded undo changes.
- The [memory optimization report](MEMORY_OPTIMIZATION_2026-09-28.md) and [memory profile](MEMORY_PROFILE_2026-09-28.md) cover an isolated real-RAW renderer workload on an 8 GB M1 MacBook Air. They do not establish whole-app peak memory for a 100–200-photo job.
- A real 100–200-distinct-photo UI workflow, combined process-memory profile, current hands-on photo UI acceptance, and macOS 15/Swift 6.1 floor validation remain open.
- The batch-delivery MVP is implemented in the current worktree. Its [active ExecPlan](../plans/active/batch-delivery-mvp.md) tracks automated and real-shoot acceptance. Persistent recipes, metadata/IPTC, watermark, sharpening, P3, and video export remain later work.

The coding workflow bootstrap is complete; its [completed plan](../plans/completed/agentic-bootstrap.md) records the Auto Tone baseline repair. The batch JPEG queue has a passing automated gate (247 tests), a signed local build, and a two-photo real-RAW UI check with collision and Stop behavior. See [batch verification](BATCH_DELIVERY_2026-09-29.md) and the [active batch-delivery plan](../plans/active/batch-delivery-mvp.md). A 100–200-distinct-photo export and whole-app memory/throughput profile are still required before the delivery milestone can close.
