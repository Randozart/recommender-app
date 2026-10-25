#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
set -euo pipefail
cd "$(dirname "$0")/../../.."
BV=${BRIEVC:-./target/debug/brievc}
out=${ACTIVE_PROFILE_OUTPUT:-target/recommender-I06}
mkdir -p "$out"
"$BV" build tests/fixtures/recommender/active_profile_gate.bv --out "$out" > "$out/edge-build.log" 2>&1
RECOMMENDER_TRACE=1 timeout 90 "$out/active_profile_gate" | tee "$out/edge.log"
if [ -n "${CACHE_PATH:-}" ]; then
    "$BV" build tests/fixtures/recommender/active_profile_full_gate.bv --out "$out" > "$out/full-build.log" 2>&1
    RECOMMENDER_TRACE=1 timeout 240 "$out/active_profile_full_gate" | tee "$out/full.log"
    "$BV" build tests/fixtures/recommender/active_profile_reuse_gate.bv --out "$out" > "$out/reuse-build.log" 2>&1
    timeout 90 "$out/active_profile_reuse_gate" | tee "$out/reuse.log"
fi
