# Target-Mac baseline observations

Date: 2026-10-21. Measurement code pin: `0d3283aa9063bb081ac39554a66221c5e87db53f`. Documentation/tooling changes do not alter the renderer. Rules: [PERFORMANCE_TARGETS](../../PERFORMANCE_TARGETS.md). **WP-004 NOT VERIFIED:** this is a nine-file diagnostic, not genuine single-shoot or whole-app acceptance.

## Provenance

| Property | Captured value / method |
| --- | --- |
| Hardware | `MacBookAir10,1`, Apple M1; `sysctl -n hw.model machdep.cpu.brand_string`, independently checked |
| Installed RAM | 8,589,934,592 bytes (8 GiB), `sysctl -n hw.memsize` |
| macOS | 26.6.2, build 25G83 (`sw_vers`) |
| Active developer directory | `/Library/Developer/CommandLineTools`; full Xcode version unavailable (`xcodebuild -version` requires full Xcode) |
| Swift | 6.4, `swiftlang-6.4.0.34.1`, driver 1.168.6; arm64 target |
| Default / measured SDK | Default SDK 27 macro-plugin discovery failed. Measured tests use installed `MacOSX26.5.sdk`; no SDK installed or global preference changed |
| Source / candidate | Source pin above; branch `codex/mpkb-v2-m0-baseline`; working docs/tooling changes recorded separately, no app-source diff |
| Dataset | Nine distinct copied DC-S5 RW2s, 325,018,624 bytes; model/EXIF whitelist checked, opaque IDs only. No JPEG capture pairs; scenarios, firmware and capture mode unknown |
| Dimensions | Native 6000×4000; oriented images include 4000×6000 and 6000×4000. Portrait orientation exposed a width-only test assumption |
| Storage | Checkout, copies, derivatives and build scratch on external SSD; initial free space 210 GiB external / 37 GiB internal |
| Environment log | External helper `m0-target-mac-baseline.sh`, environment-only run at 16:12:41 UTC; private `target-environment/environment.txt` |

Memory diagnostic command (fresh process, app not launched for M0):

```sh
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
PME_RUN_MEMORY_PROFILE=1 PME_RAW_SAMPLE_DIR="$M0_COPIES" \
  ./scripts/test.sh --build-system native --no-parallel --filter MemoryPerformanceTests
```

The existing diagnostic caps input at 16 but received **9**. Its hard-coded log labels “16 thumbnails” / “plus 10 cull previews” therefore refer to **nine actual thumbnails/cull images**, not 16/10 measured files. It retains cull images differently from the app; do not interpret this as app RSS. Default editing/focus-export context targets are 256/128 MiB; these are allocation targets, not thresholds or whole-process caps. See private `memory-nine-copies.log`; 1 executed / 0 skipped / 0 failed, build PASS.

## Diagnostic observations (no performance thresholds assigned)

| Operation | Observation | Gate interpretation |
| --- | --- | --- |
| Fresh process baseline footprint | 5.45 MiB | PASS capture only |
| Four cold working sources | 5,282.83 ms total; current footprint 740.63 MiB, cumulative peak 803.07 MiB | PASS capture only; not cold-cull UI latency |
| Warm exposure preview | Median 10.26 ms, max 14.24 ms over 15 renders | PASS capture only; not RAW WB drag feel |
| Initial 100% focus | 630.39 ms; footprint 1,242.86 MiB, cumulative peak 1,330.61 MiB | PASS capture only |
| Focus pan | Median 6.58 ms, max 7.38 ms over 10 pans | PASS capture only |
| After leaving focus | 192.77 MiB footprint after existing one-second diagnostic pause | PASS capture only; no release-time acceptance claim |
| Full-resolution JPEG export | 469.82 ms for one frame | PASS capture only; no batch throughput claim |
| After export | 195.75 MiB footprint; cumulative peak remains 1,330.61 MiB | PASS capture only |
| Budgeted vs unrestricted RAW preview | Maximum channel difference 0/255 | PASS for sampled preview pixels, not photographic acceptance |
| Held RAW WB diagnostic | First ticks 102–375 ms (5); later 104–487 ms (15); mixed focused-suite process/load | PASS capture/correctness only; no speedup or subjective smoothness claim |
| WB diagnostic footprint | Held peak 826 MiB, fresh-per-tick peak 885 MiB; immediate evict snapshots remained high | PASS capture only; neither is a whole-app RAM cap |
| Procedural repair/export diagnostic | Eight bounded/unrestricted JPEG variants; heal/combined max difference 0/255 | PASS sampled numerical agreement; visual output/segmentation NOT VERIFIED |

These are one-run observations at the pin, not performance acceptance. Other application/process load was not controlled or established; no quiet-machine comparison is claimed. No candidate renderer changed, no matched before/after performance experiment was performed, and no latency assertions were added to ordinary CI.

## Required whole-app workload still open

| Required gate | Result | Evidence needed |
| --- | --- | --- |
| Genuine 100–200 distinct RW2 single shoot | NOT VERIFIED | Owner-approved representative shoot; nine files cannot satisfy it |
| Import, cold/warm cull latency | NOT VERIFIED | Fresh app process, explicit cold/warm conditions, displayed transitions and timings |
| RAW WB drag feel | NOT VERIFIED | Human interaction on the target; exact-render tests alone insufficient |
| Focus, masks, export quality | NOT VERIFIED | Photographer evaluates focus pixels, boundaries, highlight/color and preview/export agreement |
| Save/open, cancellation/failure recovery in UI | NOT VERIFIED | Displayed app workflow; deterministic reopen checks are separate evidence |
| Whole-app peak and post-focus/export footprint | NOT VERIFIED | Process physical footprint throughout representative shoot, retention/release observations |
| Baseline/candidate matched comparison and limits | NOT VERIFIED | Agree measured operation-specific thresholds before claiming completion |
| Final highlight look / intermittent black canvas | NOT VERIFIED | Owner acceptance / causal reproduction and repeated transition evidence |

Historical October 7 varied-library and later branch results remain in existing archive reports; they are not reruns here. Record next run's revision, dirty state, hardware/OS/toolchain/SDK, private fixture IDs/hashes, unique count/bytes/scenarios, app build, other process load, timings, physical-footprint sampling and user observations. Follow the existing target-Mac active plan; do not manufacture a pass threshold from the values above.
