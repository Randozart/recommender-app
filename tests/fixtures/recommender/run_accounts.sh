#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
set -eu
cd "$(dirname "$0")/../../.."
BV=${BRIEVC:-./target/debug/brievc}
: "${PGUSER:?Set PGUSER to the dedicated test role}"
: "${PGDATABASE:?Set PGDATABASE to the dedicated test database}"
export PGUSER PGDATABASE
out=$(mktemp -d /tmp/briev-account-gates.XXXXXX)
trap 'rm -f "$out"/*.ll "$out"/sessions_gate "$out"/accounts_gate "$out"/account_state_gate; rmdir "$out"' EXIT
for gate in sessions_gate accounts_gate account_state_gate; do
    "$BV" build "tests/fixtures/recommender/$gate.bv" --out "$out"
    "$out/$gate"
done
