#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
set -eu
cd "$(dirname "$0")/../../.."
BV=${BRIEVC:-./target/debug/brievc}
: "${PGUSER:?Set PGUSER to the dedicated test role}"
: "${PGDATABASE:?Set PGDATABASE to the dedicated PostgreSQL test database}"
export PGUSER PGDATABASE
export PGHOST=127.0.0.1
out=$(mktemp -d /tmp/briev-recommender-i07.XXXXXX)
cleanup() {
    psql -X -q -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" -c 'DROP SCHEMA IF EXISTS briev_recommender_i07 CASCADE' >/dev/null 2>&1 || true
    rm -f "$out"/*.ll "$out"/operation_store_gate
    rmdir "$out"
}
trap cleanup EXIT
psql -X -q -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" -c 'DROP SCHEMA IF EXISTS briev_recommender_i07 CASCADE'
"$BV" build tests/fixtures/recommender/operation_store_gate.bv --out "$out"
"$out/operation_store_gate"
