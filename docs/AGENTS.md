# Perception Media Editor agents

The editor now has a local-first agent surface under the **Agents** workspace. Every workflow agent follows the same boundary:

```text
inspect → report → propose → approve → apply project metadata → verify
```

Agents never modify original media. Two kinds of proposal can be applied, both as non-destructive project metadata: Batch Editing copies one photo's adjustments to others, and Look Matching sets each photo to adjustments computed for that photo. Only selected proposals are applied, as one undo step. Export, relink, metadata writes, and delivery actions remain report-only until their target UI and approval details are implemented.

## In-app workflow agents

- **Photo Culling** — missing originals, duplicate filenames, and low-resolution review flags.
- **Look Matching** — groups the shoot into lighting scenes (capture-time gap, as-shot white balance in mired, exposure value from ISO/shutter/aperture, Vision feature-print distance between consecutive frames). In each scene it finds the edited hero (the selected photo if it is edited, otherwise the photo with the most edited look groups) and proposes adjustments for every unedited photo: the hero's look, the hero's RAW white balance offset carried from each photo's own as-shot value, and exposure matched on median brightness within ±1.5 EV, with a small highlights/shadows nudge. Each proposal has a confidence; those below 60% are flagged and left unselected. Photos that already have a look edit are skipped and listed, and a scene with no edited photo gets no proposals and a suggested hero. Crop, rotation, straighten, brush strokes and retouches always stay with their photo. Analysis runs at 512 px on its own actor; nothing from it is saved in the project. Thresholds are starting values until tuned on a real family-portrait shoot ([LM1 plan](../plans/active/look-match-agent.md)).
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
