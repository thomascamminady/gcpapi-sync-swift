#!/usr/bin/env bash
# Build everything (tests included) and fail on any compiler warning in this repository's
# code. Swift has no per-package "warnings as errors" switch that leaves dependencies alone,
# so the build log is checked instead.
set -euo pipefail
log=$(mktemp)
trap 'rm -f "$log"' EXIT
swift build --build-tests "$@" 2>&1 | tee "$log"
if grep -E "(warning|error):" "$log" | grep -v "/\.build/checkouts/" | grep -q .; then
    echo "error: the build produced warnings (see above)" >&2
    exit 1
fi
