# Perception Media Editor development instructions

## Mission and source of truth

Build a dependable, non-destructive macOS editor for Perception Media's photo-first workflow. The immediate user is one photographer editing 100–200 Lumix S5 RAW files on an 8 GB M1 MacBook Air. Preserve original media and recoverable project edits. Video work resumes after the photo workflow gates in [docs/ROADMAP.md](docs/ROADMAP.md).

Read only the documents relevant to the task:

- Product direction and phase order: [docs/ROADMAP.md](docs/ROADMAP.md)
- Current implementation and open acceptance: [docs/CURRENT_STATUS.md](docs/CURRENT_STATUS.md)
- Component and persistence boundaries: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- Coding and data contracts: [docs/CODING_STANDARDS.md](docs/CODING_STANDARDS.md), [docs/DATA_MODEL.md](docs/DATA_MODEL.md)
- Verification and hardware evidence: [docs/TESTING_STRATEGY.md](docs/TESTING_STRATEGY.md), [docs/PERFORMANCE_TARGETS.md](docs/PERFORMANCE_TARGETS.md)
- Developer workflow: [.agent/PLANS.md](.agent/PLANS.md), [.agent/ROLES.md](.agent/ROLES.md)
- In-app workflow agents: [docs/AGENTS.md](docs/AGENTS.md). These are a product feature, separate from coding-agent roles.

If a document disagrees with code or another document, identify the discrepancy and update the appropriate source after verifying behavior. Historical QA reports record evidence at their stated revision; do not treat them as current passes.

## Working rules

- Inspect the worktree before editing. Preserve unrelated changes, including uncommitted work.
- Do not write to original media. Use disposable fixtures for tests. Keep `.pmedit` changes compatible or explicitly version the schema and test old files.
- Keep expensive decoding, rendering, hashing, and waveform work off the main actor. Respect cancellation, project identity, bounded caches, and memory pressure.
- Preserve the shared photo/video color contract and distinguish preview quality from full-resolution export quality.
- Use an ExecPlan for substantial features, cross-component changes, migrations, or major refactors. Follow [.agent/PLANS.md](.agent/PLANS.md). Small isolated fixes can proceed directly.
- For changes to documented behavior, update the relevant docs and [docs/CURRENT_STATUS.md](docs/CURRENT_STATUS.md) in the same task.
- Use specialized roles only when the task benefits from independent work and the current session permits delegation. Assign file ownership and integrate the result before reporting completion.

## Completion gate

Run the applicable checks in [docs/TESTING_STRATEGY.md](docs/TESTING_STRATEGY.md). Report each required gate as **PASS**, **FAIL**, or **NOT VERIFIED** with the command or reason. Never infer a hardware, visual, real-RAW, or performance pass from synthetic tests. A milestone is complete only when its written acceptance criteria and required gates pass; otherwise keep it active and name the remaining work.

In the completion report, state what changed, tests run, performance implications, limitations, and the next roadmap item.
