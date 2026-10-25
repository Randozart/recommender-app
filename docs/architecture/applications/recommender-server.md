# Recommender backend server

`examples/recommender/server.bv` is the native reactor entry. It creates the
base schema and durable rating-receipt table, performs guarded baseline
bootstrap and constructs a consistent engine snapshot before listening. There
is no authored main function. The perpetual
serve node calls one poll sweep at a time. All application/protocol/client code
is Briev; PostgreSQL is external infrastructure.

## Configuration and wire API

PostgreSQL is trust-authenticated on 127.0.0.1:5432 using PGUSER/PGDATABASE.
UDATA_PATH defaults to u.data. UITEM_PATH defaults to u.item and supplies the
MovieLens-100k movie titles. The server loads and validates this catalogue once
before opening its listener; it requires exactly 1682 rows with IDs 1 through
1682 in order and nonempty titles. `u.item` title bytes are ISO-8859-1 and are
converted to UTF-8 before JSON serialization. Keep the data file local and
configured; it is not copied into this repository. PORT defaults to 8080;
MAX_CONNECTIONS to 1024;
LAMBDA_MILLI to 500 (0..1000 means lambda 0..1); REFRESH_SECONDS to 300.
`CACHE_PATH` defaults to `recommender.snapshot.bin`. Its directory must already
exist and be writable for durable reuse and refresh worker handoff.
Invalid configuration or failed bootstrap fails startup with a concrete error.

POST /v1/register and /v1/login accept username/password JSON strings; the
unversioned paths remain aliases. Registration returns protocol version and
type fields. Login also returns the opaque process-local token, account ID,
username and this process's random server epoch. The epoch is preserved across
server-state copies and changes on restart. GET /v1/state?token=... returns a
versioned profile envelope with that owner's identity, ratings, current in-memory
revision and retained operation summaries; `/state` remains an alias. POST
/v1/operations/status?token=... returns in-memory status for up to 64
requested operation IDs. Uncertain operations are reconciled against durable
receipts by the persistence child when it is idle; while it is busy, the reactor
returns its cached status snapshot.
POST /v1/operations/{id}/retry and `/discard` queue resolution for a
definitively failed operation. POST /v1/logout?token=... revokes only that process-local
session (`/logout` is an alias), closes live channels opened with that token,
and leaves other sessions for the account valid. POST /rating accepts
token/item_id/rating and performs an account-scoped upsert. GET /movies returns
the ordered catalogue as `{movies:[{item_id,title},...]}`, using zero-based IDs
and MovieLens titles. GET
/recommendations?token=... returns cold_start:true below five distinct ratings,
or recommendations ordered by descending score and ascending item ID.
POST /admin/refresh schedules a snapshot rebuild; this demo endpoint has no
separate admin-auth scheme. OPTIONS responds with permissive CORS headers.

GET /v1/live?token=... (also `/live`) requires a version-13 WebSocket handshake with a valid
16-byte nonce. After upgrade, JSON text accepts item_id/rating. A token in the
frame never changes its connection owner. The reactor binds each live channel to
the exact token used at upgrade; logout closes channels for that token, while
other sessions for the same account remain usable. Successful HTTP or live
ratings publish accepted, recommendation, and save events to that owner's open
channels only. HTTP fallback POST `/v1/ratings?token=...` returns 202 with the
accepted event. Validation errors go to the submitting channel. Ping receives
Pong; Close is echoed.
Masked client frames, fragmented text and interleaved control frames are
supported. Invalid RSV/opcode/masking/length/UTF-8/fragment sequences close with
the appropriate protocol code. Binary messages are unsupported (1003).

## Ownership and scheduling

The current integration runs one persistence child and one prediction child.
Each channel permits one outstanding request, so at most one new rating is
admitted globally at a time; excess work receives 503 and can be retried. The
reactor polls both channels nonblocking and does not execute login, persistence,
or prediction on the rating request path. Worker counts remain explicit startup
configuration points for later scaling.

server_io.bv owns bounded raw input/output buffers. It reads or sends at most
one syscall's bytes per connection per sweep. EAGAIN/EINTR preserve progress.
Output queues retain their unsent suffix when another push arrives. HTTP sends
Connection: close and closes only after its output drains. The upgrade retains
any trailing frame bytes received with its HTTP headers. EOF preserves a queued
HTTP response; hard failures release the connection and its buffers.
An unusable listener/poll set fails the service with a flushed diagnostic rather
than spinning on a permanently failing descriptor.

Each connection has at most 64 KiB of accumulated input, 64 KiB of fragmented
text and 1 MiB of queued output. Exceeding a limit rejects/closes that peer.
HTTP framing rejects invalid/duplicate Content-Length and Transfer-Encoding;
JSON parsing rejects malformed grammar, duplicate application fields, noninteger
ratings and trailing input. JSON nesting is limited to 64 and integers to Int.
Slots, socket descriptors and buffer lifetimes belong to the single reactor;
copied Reactor/ServerModel values alias owned storage and must not be freed twice.

## Population and prediction state

server_model.bv reads baseline and account rows in one repeatable-read database
snapshot using bounded cursor pages. Accounts sorted by ID map to dense rows
after the 943 baseline rows. Deleted/skipped database IDs never become engine
indices. The served model owns its dual CSR population, means and two similarity
matrices. Ratings are capped at ten million per model for bounded allocation.

Login and rating changes materialize one owner's recommendation result. The
active row uses current persisted account ratings; its former snapshot row is
excluded from candidates, preventing self-neighbor duplication. Active user
similarities are computed once for that update, while item similarities and
neighbor means come from the immutable served cache. Serving a recommendation
reads its owner's materialized result rather than rebuilding matrices.

The current serial path remains the numerical reference. I06's standalone
`active_profile.bv` candidate is being compared with that replacement-row
calculation before worker integration. `prediction_scratch.bv` owns one bounded
allocation for unchanged population base similarities and reusable active
profile/candidate/top-k buffers. Its model is borrowed and immutable; each
installed generation gets its own worker-local workspace, released before its
model. The typed prediction boundary consumes I02's `PredictionRequest` and
returns `RecommendationResult`; I08 owns process dispatch and publication.

Explicit and periodic refreshes fork a Linux worker. The child closes inherited
reactor and PostgreSQL descriptors WITHOUT sending protocol shutdown messages,
opens its own database session in the parent's schema, and loads/builds a complete
replacement snapshot. The parent uses nonblocking wait4, keeps serving the old
snapshot, and installs a validated worker artifact only after successful exit.
The child exits with the parent (prctl plus parent-PID recheck); completed children
are reaped. Requests during a build coalesce into one queued refresh. Failure
keeps the old model and permits retry; one owner's materialized view is refreshed
and pushed per sweep after installation. Cold startup still waits for its first
model. This does not promise a bound on ordinary owner-recommendation computation
or on the one-time snapshot decoding/copy at installation.

`cf_prepared.bv` memoizes both base-PCC matrices and both orientations of imputed
ratings. Orientations are represented by CSR/mean data and share one algorithm.
Final PCC still walks each pair's original observed union in the original order.
Each orientation's scratch base/imputed arrays are freed before the next stage;
the original direct engine remains the numerical reference. No approximate
neighbors, changed key sets, or compiler algorithm recognition are introduced.

`model_snapshot.bv` persists the ENTIRE model, not just its matrices, so a refresh
never combines one database population with another cache. A statement trigger
on accounts, ratings and baseline_ratings advances model_revision in the same
transaction as INSERT/UPDATE/DELETE/TRUNCATE; rollback rolls back the revision.
A persistent epoch distinguishes recreated revision tables. Database name,
schema, epoch and revision form an exact length-delimited identity captured in
the population's repeatable-read transaction. Startup reuses only a matching
snapshot. A format/algorithm magic, bounded dimensions, exact image length and
whole-image checksum reject incompatible/truncated/damaged images before decode.
The checksum detects accidental corruption; artifacts are trusted local files,
not authenticated interchange. The native numeric ABI is part of the format.
Floating blocks copy their live typed prefix and zero spare allocation capacity.

Writes use a PID-specific temporary file, complete-write validation, file fsync,
atomic rename, and directory fsync. A failed write does not publish partial data;
the in-memory model remains usable. Cold/warm startup timing and exact-reference
gates are recorded in the cache-reuse plan; 1000-channel capacity remains task 16.

## Gates

`tests/fixtures/recommender/run_server.sh` builds native gates for API/DB
integration, reactor slots, malformed input, Unicode JSON, partial output under
forced backpressure, and register/login/rate-five/live ownership over real TCP.
The end-to-end gate uses two accounts and two channels for one owner, including
fragmented frames, a forged frame token, HTTP-triggered pushes, refresh and EOF.
It resets only briev_server_api_gate and briev_server_loop_gate schemas in a
dedicated test database. Do not run concurrent copies against that database.

The runner also executes the three tests in recommender_server_properties.rs:
128 proptest cases each for properties 5, 7 and 20, using a native Briev probe.
Interpreter checks are excluded by the user's explicit instruction.

## Responsiveness baseline instrumentation (I01)

`RECOMMENDER_TRACE=1` enables `trace.bv` diagnostics on the existing synchronous
path. `TRACE` lines contain an optional bounded ASCII operation ID, stage, and
monotonic microsecond endpoints. HTTP test drivers supply `X-Recommender-Trace`;
browser POST and live test drivers may supply an otherwise ignored `trace_id`
JSON field. IDs carry no authentication/idempotency meaning. Credentials and
session tokens are never logged. Unrelated requests clear the serial context.

Stages separate account database reads, rating write/protocol wait, active-profile
construction, candidate prediction scan, ranking/release, push queueing and request
dispatch. Queued output is not proof of delivery or browser paint. Server-clock
durations are never subtracted from browser/client clock values. Tracing is opt-in;
wire responses and write-before-predict behavior remain unchanged in I01.

The reproducible drivers and resource/clock caveats are in
`benchmarks/recommender_responsiveness/README.md`. Their DB/ports/cache/artifacts
are separate from the user's app. I02's future consistency contract does not
establish that the asynchronous production path is already implemented.

The frozen [v1 responsiveness contract](recommender-responsiveness-contract-v1.md)
defines I02's portable types/codecs, framing, persistence transition policy and
the interfaces required by I03–I17. It explicitly separates current behavior from
the future admission/worker/browser cutover. Its native/WASM contract fixtures
must pass when those boundaries change.

## Crash recovery invariants (2026-10-25)

The coordinator's returned object replaces its pooled state after every reactor
firing; discarding that assignment loses authentication requests even when the
worker and PostgreSQL complete them. Box/pool conversion uses each field's
native width. Idle slots without live sessions preserve the existing state.
Empty prediction models own both CSR boundary offsets. Worker shutdown follows
the protocol's deadline-only payload and exits only after a successful stopped
reply; a rejected request does not terminate the process.

Catalogue responses use one owned growing buffer, released after the final
String copy. Repeated immutable prefix copies previously retained approximately
412 MiB for a single 85,469-byte MovieLens response.

The real browser gate is `tests/fixtures/recommender/browser_live_server.mjs`.
It verifies registration, login, live ratings, prediction during a blocked
database save, and save confirmation without another recommendation render.
Worker-process gates separately cover shutdown/reaping, crash/restart,
generation changes, malformed messages and timeout behavior.
