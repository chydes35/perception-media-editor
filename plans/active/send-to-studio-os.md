# Send to Studio OS

Status: active  
Roadmap item: [Phase 4 delivery](../../docs/ROADMAP.md)  
Owner: lead Codex agent

## User outcome and acceptance

The photographer selects photos in a project, chooses Send to Studio OS, picks a booking's gallery, and the photos arrive as private drafts in that gallery. The transfer is resumable: an interrupted send continues without duplicating items.

Out of scope: hosted delivery, RAW/video upload, automatic gallery creation, replacing published photos, OAuth.

## Current state and affected contracts

New contracts introduced by this work: a persisted transfer queue file, one Keychain item holding the Studio OS device token, and the `perceptionedit://pair` URL scheme. No `.pmedit` schema change. Task 1 adds pairing validation, wire models and credential storage (`StudioOSModels.swift`, `StudioOSCredentialStore.swift`).

## Implementation steps

1. Models, pairing validation and credential storage (this task).
2. Remaining steps follow the server-side plan and the send-action plan linked below.

## Safety and performance

Original media is never modified; only derived JPEG renders are staged. Staging files are removed only after the server confirms the item, and never touch originals. The device token lives in the Keychain, is never logged, never stored in the queue file, and remote servers must use https (plain http only for loopback).

## Verification

| Gate | Required check | Result and evidence |
| --- | --- | --- |
| Static/build | `git diff --check`; Swift build | PENDING |
| Unit/integration | Focused and full Swift Testing as applicable | PENDING |
| Runtime/UI | Pair, send, resume against a local Studio OS | PENDING |
| Media quality | Representative RAW exports sent | PENDING |
| Performance | Target hardware and workload | PENDING |

## Decisions, discoveries, and remaining work

Links: spec `/Volumes/ExSSD1/Developer/studio-os/docs/superpowers/specs/2026-10-15-perception-edit-send-to-studio-os-design.md`; plan `/Volumes/ExSSD1/Developer/studio-os/docs/superpowers/plans/2026-10-15-perception-edit-send-action.md` (paths as found; server plan lives in the Studio OS repo).
