#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
set -eu
cd "$(dirname "$0")/../../.."
BV=${BRIEVC:-./target/debug/brievc}
: "${PGUSER:?Set PGUSER to the dedicated test role}"
: "${PGDATABASE:?Set PGDATABASE to the dedicated test database}"
export PGUSER PGDATABASE
out=$(mktemp -d /tmp/briev-server-gates.XXXXXX)
trap 'rm -f "$out"/*; rmdir "$out"' EXIT
"$BV" build tests/fixtures/recommender/movie_catalogue_gate.bv --out "$out"
timeout 60 "$out/movie_catalogue_gate"
"$BV" build tests/fixtures/recommender/browser_catalogue_gate.bv --out "$out"
timeout 60 "$out/browser_catalogue_gate"
for gate in reactor_gate server_json_gate server_api_gate server_io_gate server_protocol_gate server_loop_gate server_ws_protocol_gate server_property_gate; do
    "$BV" build "tests/fixtures/recommender/$gate.bv" --out "$out"
    if [ "$gate" != server_property_gate ]; then timeout 60 "$out/$gate"; fi
done
RECOMMENDER_PROPERTY_BINARY="$out/server_property_gate" \
    CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$HOME/briev-target}" \
    cargo test --test recommender_server_properties -- --ignored
