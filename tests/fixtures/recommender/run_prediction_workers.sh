#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
set -euo pipefail
cd "$(dirname "$0")/../../.."
BV=${BRIEVC:-./target/debug/brievc}
OUT=${PREDICTION_WORKER_OUTPUT:-target/recommender-I08}
mkdir -p "$OUT"
for gate in worker_empty_model_gate prediction_pool_gate prediction_generation_gate worker_model_gate worker_contract_checks worker_process_gate responsiveness_frame_gate; do
    "$BV" build "tests/fixtures/recommender/$gate.bv" --out "$OUT" >"$OUT/$gate.build.log" 2>&1
    GATE_TIMEOUT=60
    if [ "$gate" = worker_process_gate ]; then GATE_TIMEOUT=120; fi
    stdbuf -oL timeout "$GATE_TIMEOUT" "$OUT/$gate" | tee "$OUT/$gate.log"
done

# Optional real PostgreSQL concurrency probe. A session holds an advisory lock,
# a second DB client blocks acquiring it, and the persistent prediction process
# must still finish its independent in-memory work before the blocked query ends.
if [ -n "${RECOMMENDER_TEST_DATABASE_URL:-}" ]; then
    KEY=$((77583008 + $$))
    psql -X "$RECOMMENDER_TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -At \
        -c "SELECT 'lock-ready', pg_advisory_lock($KEY)" -c "SELECT pg_sleep(45)" \
        >"$OUT/db-lock-holder.log" 2>&1 &
    HOLDER=$!
    BLOCKER=
    cleanup_db_probe() {
        if [ -n "$BLOCKER" ]; then kill "$BLOCKER" 2>/dev/null || true; wait "$BLOCKER" 2>/dev/null || true; fi
        kill "$HOLDER" 2>/dev/null || true
        wait "$HOLDER" 2>/dev/null || true
    }
    trap cleanup_db_probe EXIT
    for _ in $(seq 1 100); do
        if grep -q lock-ready "$OUT/db-lock-holder.log"; then break; fi
        sleep 0.05
    done
    grep -q lock-ready "$OUT/db-lock-holder.log"
    psql -X "$RECOMMENDER_TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -Atc \
        "SELECT pg_advisory_lock($KEY)" >"$OUT/db-lock-waiter.log" 2>&1 &
    BLOCKER=$!
    sleep 0.25
    if ! kill -0 "$BLOCKER" 2>/dev/null; then
        echo "database advisory-lock waiter did not block" >&2
        exit 1
    fi
    stdbuf -oL timeout 120 "$OUT/worker_process_gate" | tee "$OUT/worker_process_while_db_blocked.log"
    kill -0 "$BLOCKER"
    echo "prediction_completed_while_db_waiter_blocked=true"
    cleanup_db_probe
    trap - EXIT
else
    echo "database_block_probe=skipped (set RECOMMENDER_TEST_DATABASE_URL)"
fi
