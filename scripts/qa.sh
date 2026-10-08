#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"

print "== Diff hygiene =="
git diff --check

print "== Developer source review =="
./scripts/agent-review.sh all

print "== Swift tests and app build =="
./scripts/test.sh --no-parallel

print "Automated QA passed. Runtime UI, real-media quality, and target-hardware performance require separate evidence."
