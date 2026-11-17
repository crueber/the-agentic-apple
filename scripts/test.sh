#!/bin/bash
# Offline self-test (no real accounts needed). Optional suite filter: scripts/test.sh Claude
set -euo pipefail
cd "$(dirname "$0")/.."
swift run --scratch-path "${SCRATCH_PATH:-.build}" agentic-selftest "$@"
