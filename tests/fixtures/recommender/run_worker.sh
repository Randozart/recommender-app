#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
set -eu
cd "$(dirname "$0")/../../.."
BV=${BRIEVC:-./target/debug/brievc}
out=$(mktemp -d /tmp/briev-worker-gates.XXXXXX)
trap 'rm -f "$out"/*.ll "$out"/worker_model_gate "$out"/worker_process_gate "$out"/responsiveness_frame_gate; rmdir "$out"' EXIT
for gate in worker_model_gate worker_process_gate responsiveness_frame_gate; do
    "$BV" build "tests/fixtures/recommender/$gate.bv" --out "$out"
    timeout 45 "$out/$gate"
done
