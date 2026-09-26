# Perception Media Editor agents

The editor now has a local-first agent surface under the **Agents** workspace. Every workflow agent follows the same boundary:

```text
inspect → report → propose → approve → apply project metadata → verify
```

Agents never modify original media. The only currently applicable proposal copies non-destructive photo adjustments between project assets. Export, relink, metadata writes, and delivery actions remain report-only until their target UI and approval details are implemented.

## In-app workflow agents

- **Photo Culling** — missing originals, duplicate filenames, and low-resolution review flags.
- **Look Matching** — proposes copying the selected photo's global adjustments to comparable photos.
- **Batch Editing** — prepares a reversible batch adjustment pass from the selected photo.
- **Photo Quality Control** — checks source availability and basic delivery readiness.
- **Video Continuity** — checks source availability, duration, frame-size consistency, and timeline assembly.
- **Delivery Planning** — prepares a no-write delivery checklist.
- **Metadata & Organization** — reports missing metadata coverage.
- **Relink & Recovery** — reports missing references and prepares a safe manual recovery step.
- **Project Health** — checks the current project against a photo/video production workflow.

## Developer reviewers

Run `scripts/agent-review.sh` from the repository root:

```sh
./scripts/agent-review.sh all
./scripts/agent-review.sh workflow
./scripts/agent-review.sh renderer
./scripts/agent-review.sh schema
./scripts/agent-review.sh compatibility
./scripts/agent-review.sh release
```

These are deterministic source reviewers for the app itself. They cover workflow surface, render performance boundaries, project schema, media compatibility, and release readiness. They do not replace scenario-based manual QA or model-backed code review.

## Extension points

The agent model is intentionally separate from `EditorProject`. A future Vision or local model integration can add focus, eye, subject, scene, color, and continuity signals without making those results part of the source-of-truth project until the user approves them.
