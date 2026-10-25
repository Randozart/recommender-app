#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
set -eu
cd "$(dirname "$0")/../../.."
BV=${BRIEVC:-./target/debug/brievc}
out=$(mktemp -d /tmp/briev-active-scratch.XXXXXX)
trap 'rm -rf "$out"' EXIT
"$BV" build tests/fixtures/recommender/active_scratch_gate.bv --out "$out"
timeout 30 "$out/active_scratch_gate"
