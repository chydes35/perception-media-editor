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

Updated 2026-10-15. The GUI and hardware gates of the original Task 7 were replaced, by a recorded controller ruling, with an automated live-server check; the replaced gates stay **NOT VERIFIED** and are not substituted.

| Gate | Required check | Result and evidence |
| --- | --- | --- |
| Static/build | `git diff --check`; Swift build | PASS: `git diff --check` clean and the build completes (CLT-only toolchain, see discoveries). |
| Unit/integration | Focused and full Swift Testing | PASS: full suite after Tasks 1-6 was 364 tests, 344 passed, 21 skipped, 0 failed (skips need private RAW inputs or opt-in env vars). Fake-server suites: `StudioOSPairingTests`, `StudioOSClientTests`, `TransferQueueStoreTests`, `TransferOrchestratorTests`, `StudioOSControllerTests`. Final run with the live suite added (it skips without its env vars): 368 tests in 76 suites, 0 failed, 25 `skipped` lines (the 4 live tests plus the existing opt-in/RAW tests). |
| Live server (automated) | Real `StudioOSClient`, `TransferOrchestrator` and `TransferQueueStore` against a running Studio OS on the throwaway `studio_os_test` database | PASS: 4 of 4 `StudioOSLiveServerTests` passed (localhost, 2026-10-15): 5 photos to `ready` drafts with staging removed; cancel mid-upload then resume from a new store and orchestrator (8 photos, each rendered once, 8 server items); idempotent manifest (same ids on repeat, changed size rejected 409); revoked token pauses with "not paired" and rendered files kept. Dev database `studio_os` user count unchanged (1) before and after; `studio_os_test` gained the throwaway owner. Photos are small synthetic JPEGs, not RAW renders. |
| Runtime/UI: pairing alert, pairing link, panel, destination sheet | Pair a Mac from the Account page, click `perceptionedit://pair`, send from the Export workspace | NOT VERIFIED: no GUI session. The controller logic behind these is unit-tested only. |
| Server-side publish gate | A sent photo is absent from the client gallery link until published | NOT VERIFIED here (needs the web UI). Drafts were confirmed through the API (`publicationState: draft`) only. |
| Failure drills with a real server stop/restart, quit and relaunch of the app, disk-full staging volume | Task 7 Step 3 (a), (b), (d) | NOT VERIFIED. Cancel/resume across a fresh store and orchestrator and a revoked token are covered by the live suite; API stop mid-batch, app quit and a full volume were not exercised against a live server. |
| Media quality | Color, orientation, crop, dimensions and order of a real RAW shoot in the Studio OS gallery; RAW hashes unchanged | NOT VERIFIED: no genuine shoot was sent. Order is checked in the unit tests (positions) and in the live suite only as manifest identity. |
| Performance | M1/8 GB Air, staging on the external SSD, 100-200 photos: peak memory, staging disk, elapsed time | NOT VERIFIED: target Mac and genuine shoot not used. |

## Decisions, discoveries, and remaining work

Links: spec `/Volumes/ExSSD1/Developer/studio-os/docs/superpowers/specs/2026-10-15-perception-edit-send-to-studio-os-design.md`; plan `/Volumes/ExSSD1/Developer/studio-os/docs/superpowers/plans/2026-10-15-perception-edit-send-action.md` (paths as found; server plan lives in the Studio OS repo).

### Discoveries (Task 7)

- The Mac has only Command Line Tools. Build and test with `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ./scripts/test.sh -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing --no-parallel`; `scripts/test.sh` itself is unchanged.
- The server flows exercised live: `POST /integrations/perception-edit/v1/transfers` (idempotent per `clientTransferId`, 409 for a changed manifest), `GET .../transfers/:id`, `POST .../items/:id/upload-url`, presigned PUT to the storage host (no bearer token attached), `POST .../items/:id/complete`, preview processing reaching `ready` with `publicationState: "draft"`, and 401 for a revoked device token (surfaced as the "not paired" pause).
- A file upload through `URLSession.upload(for:fromFile:)` worked against the MinIO presigned URL; no body-stream workaround was needed.
- The server worker logged "Checksum mismatch" for preview jobs left over from older test-database runs; unrelated to these transfers.
- No editor defects were found by the live run.

Remaining work: the NOT VERIFIED rows above. Keep this plan in `plans/active/` until they are measured.
