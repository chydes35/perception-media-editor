#!/bin/zsh
set -euo pipefail
ROOT_DIR="${0:A:h:h}"
export PME_RUN_MEMORY_PROFILE=1
exec "$ROOT_DIR/scripts/test.sh" --filter MemoryPerformanceTests "$@"
