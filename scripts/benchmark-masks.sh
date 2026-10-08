#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"

# Run the timing suite in isolation; correctness tests still run in the normal test script.
PME_RUN_MASK_BENCHMARKS=1 ./scripts/test.sh --filter MaskPerformanceTests
