# Recommender task 10 gates

Run from WSL with PostgreSQL on 127.0.0.1:5432, a dedicated trust-auth role and
database, and the current integration compiler:

```bash
BRIEVC=/home/otto/briev-target/debug/brievc PGUSER=briev_test PGDATABASE=briev_recommender_test bash tests/fixtures/recommender/run.sh
```

The runner builds into a temporary directory. It checks parser semantics, object
Result payloads and both wrong-side traps, atomic/idempotent bootstrap, exact
small-population contents, missing/incomplete/error/empty population paths,
account/item upsert isolation, validation, foreign keys, caller transaction
ownership, late-batch rollback, duplicate keys across batch boundaries, and two simultaneous
startup loaders producing exactly one completed load.

It creates/resets only its own schemas: briev_bootstrap_gate,
briev_population_edge_gate, briev_upsert_gate, briev_batch_gate, briev_guard_gate, and briev_concurrent_gate. Do not run
concurrent copies against the same database. A failed run may leave its schema
for diagnosis; reruns expect their standard schema, without injected constraints
or renamed tables from an interrupted run.

Set FULL_BASELINE=1 to additionally reconstruct public.baseline_ratings and check
both orientations against its count and sum. This requires successful bootstrap;
it does not load or alter the public dataset. Full verification has also compared
all 100,000 persisted baseline tuples independently with the source u.data.

## Task 11 account gates

```bash
BRIEVC=/home/otto/briev-target/debug/brievc PGUSER=briev_test PGDATABASE=briev_recommender_test bash tests/fixtures/recommender/run_accounts.sh
```

This separate runner checks 144 credential combinations (including all Unicode
whitespace classes), FNV vectors, parameterized registration/duplicates/login,
explicit session ownership and token encoding, 120 account-isolation cases,
empty/deleted accounts, forged/restarted sessions, and database-error recovery.
It resets only briev_accounts_gate and briev_account_state_gate. Sessions are
process-local; credentials and ratings are PostgreSQL-backed. Recommendations
are composed by the server in task 12 using the same authenticated owner.

## Task 12 server gates

```bash
BRIEVC=/home/otto/briev-target/debug/brievc PGUSER=briev_test PGDATABASE=briev_recommender_test bash tests/fixtures/recommender/run_server.sh
```

This runner compiles native reactor, JSON, API, transport, protocol and complete
HTTP/WebSocket loopback gates. It forces partial writes, checks fragmented live
ratings, two channels owned by one account and a foreign channel, HTTP-triggered
pushes, refresh mapping, malformed framing, half-close and failed refresh.
It also runs 128 proptest cases for each of properties 5, 7 and 20 through the
native property probe. PostgreSQL gates reset only briev_server_api_gate and
briev_server_loop_gate. Do not run copies concurrently against the same test DB.

The runner also checks MovieLens `u.item` parsing, contiguous zero-based IDs,
title JSON serialization, malformed catalogue rejection, and Latin-1-to-UTF-8
conversion. Set `UITEM_PATH` when running the standalone catalogue gate to
verify the complete local 1682-item dataset; without it, the gate uses parser
samples only.

Build the service with `brievc build examples/recommender/server.bv --out <dir>`;
configure PGUSER, PGDATABASE, UDATA_PATH and UITEM_PATH before running it. PORT defaults to
8080, MAX_CONNECTIONS to 1024, LAMBDA_MILLI to 500 and REFRESH_SECONDS to 300.
See docs/architecture/applications/recommender-server.md for the wire contract.

## I11 real browser/server integration gate

Run this gate only with a dedicated PostgreSQL test database and the browser
dependencies installed. It builds both the native server and split WASM/host app
from the current checkout, records their hashes, and runs Playwright against the
real server on port 18110. The test registers a unique account, seeds five
ratings in that account, then holds its PostgreSQL account row while changing a
rating in the browser. It releases the lock only after the fresh recommendation
has arrived and appeared in the page.

```bash
PGUSER=briev_test PGDATABASE=briev_recommender_test \
  PLAYWRIGHT_MODULE=/path/to/node_modules/playwright \
  python3 benchmarks/recommender_responsiveness/run_i11_browser.py \
    --compiler /home/otto/briev-target/release/brievc \
    --output /tmp/recommender-i11-browser-run
```

The PostgreSQL server must listen on 127.0.0.1:5432. `PGHOST`, `PGPORT`,
`PSQL`, `NODE`, `PLAYWRIGHT_CHANNEL` and `PLAYWRIGHT_MODULE` can select local
tools; the app and server source revision is the checkout used by the runner.
The output directory must not already exist. It retains build logs, server log,
source/artifact hashes and the gate result for review. The runner stops only the
server process it starts.

## Task 13 integrated checkpoint

The backend/net-stack checkpoint is complete on `integration/ptr-provenance`.
The three runners above, the reference/CF/cache probes, native compiler/stdlib
regressions and ByteSink/socket/net-stack golden tests pass together. The full
library suite has 3169 passes and exactly the 38 environment failures explicitly
accepted by the user. See
`docs/plans/2026-10-21-backend-checkpoint.md` for commands, branch commits and the
existing LLVM Praetor/full-determinism limitations. Optional unfinished tasks
remain skipped; frontend work starts at task 14.
