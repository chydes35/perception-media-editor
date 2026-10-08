# <Feature or change>

Status: active  
Roadmap item: <link>  
Owner: <name or role>

## User outcome and acceptance

Describe what the photographer can do when this is complete. List measurable acceptance criteria and out-of-scope work.

## Current state and affected contracts

Record relevant files, existing behavior, `.pmedit` fields/schema, shared photo/video rendering contracts, and assumptions verified in code.

## Implementation steps

List ordered steps and record progress as each is completed. Identify any independently owned files if work is delegated.

## Safety and performance

Explain original-media protection, save/recovery behavior, cancellation, peak memory, and target-hardware implications as applicable.

## Verification

| Gate | Required check | Result and evidence |
| --- | --- | --- |
| Static/build | `git diff --check`; Swift build | PENDING |
| Unit/integration | Focused and full Swift Testing as applicable | PENDING |
| Runtime/UI | Relevant real workflow | PENDING or NOT APPLICABLE with reason |
| Media quality | Representative RAW/video fixtures | PENDING or NOT APPLICABLE with reason |
| Performance | Target hardware and workload | PENDING or NOT APPLICABLE with reason |

## Decisions, discoveries, and remaining work

Record design changes, limitations, and any unverified gate. Do not mark complete while required checks remain open.
