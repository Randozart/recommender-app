#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
# Run from any directory. Requires the dedicated local trust-auth test database.
set -eu
cd "$(dirname "$0")/../../.."
BV=${BRIEVC:-./target/debug/brievc}
: "${PGUSER:?Set PGUSER to the dedicated test role}"
: "${PGDATABASE:?Set PGDATABASE to the dedicated test database}"
export PGUSER PGDATABASE
out=$(mktemp -d /tmp/briev-recommender-gates.XXXXXX)
trap 'rm -f "$out"/*.ll "$out"/udata_gate "$out"/result_object_gate "$out"/bootstrap_gate "$out"/population_gate "$out"/population_edges "$out"/upsert_gate "$out"/batch_gate "$out"/guard_gate "$out"/concurrent_gate "$out"/first.log "$out"/second.log; rmdir "$out"' EXIT
"$BV" build tests/fixtures/stdlib/result_object_gate.bv --out "$out"
"$out/result_object_gate"
for gate in udata_gate bootstrap_gate population_gate population_edges upsert_gate batch_gate guard_gate; do
    "$BV" build "tests/fixtures/recommender/$gate.bv" --out "$out"
    if [ "$gate" = population_gate ]; then
        SMALL_FIXTURE=1 "$out/$gate"
    else
        "$out/$gate"
    fi
done
"$BV" build tests/fixtures/recommender/concurrent_gate.bv --out "$out"
PREPARE_GATE=1 "$out/concurrent_gate"
"$out/concurrent_gate" > "$out/first.log" &
first_pid=$!
"$out/concurrent_gate" > "$out/second.log" &
second_pid=$!
wait "$first_pid"
wait "$second_pid"
cat "$out/first.log" "$out/second.log"
test "$(grep -h -c 'concurrent_snapshot=true loaded=true accepted=65' "$out/first.log" "$out/second.log" | awk '{sum+=$1} END {print sum}')" -eq 1
test "$(grep -h -c 'concurrent_snapshot=true loaded=false accepted=0' "$out/first.log" "$out/second.log" | awk '{sum+=$1} END {print sum}')" -eq 1
echo 'simultaneous_startup_loads_once=true'
ulimit -c 0
for mode in 1 2; do
    set +e
    UNWRAP_MODE=$mode "$out/result_object_gate"
    code=$?
    set -e
    test "$code" -eq 132
    echo "wrong_side_${mode}_traps=true"
done
if [ "${FULL_BASELINE:-0}" = 1 ]; then
    SMALL_FIXTURE=0 "$out/population_gate"
fi