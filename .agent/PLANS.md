# ExecPlans and milestone workflow

Use `plans/active/<short-name>.md` for a substantial feature, cross-component change, migration, or major refactor. Copy [TASK_TEMPLATE.md](TASK_TEMPLATE.md). A plan is a living engineering contract, not an approval pause. Start implementation once scope is clear; ask the product owner only for a decision that materially changes workflow, architecture, or scope.

Each plan records observable user behavior, affected files/contracts, original-media and project-data safety, memory/performance risks, verification commands, and completion criteria. Update progress and discoveries as work proceeds. If a significant design choice changes, record it in `docs/decisions/` and link it from the plan.

For a milestone, use [MILESTONE_TEMPLATE.md](MILESTONE_TEMPLATE.md) and map it to the existing photo-first [roadmap](../docs/ROADMAP.md). The roadmap remains the product source of truth; do not invent a parallel numbered phase system. Use [REVIEW_TEMPLATE.md](REVIEW_TEMPLATE.md) for an independent review when useful.

At the end, record the gate results and evidence. Move the plan to `plans/completed/` only when all required acceptance criteria pass. A blocked or partially verified plan stays active, with the next action stated. Update [CURRENT_STATUS.md](../docs/CURRENT_STATUS.md) after substantial work.
