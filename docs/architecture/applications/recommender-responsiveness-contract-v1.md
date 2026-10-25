# Recommender responsiveness contract v1

I02 interface freeze, 2026-10-22. This specifies the I03–I17 implementation;
the running legacy server is still synchronous. Only the pure codecs, framing
and persistence transition policy are implemented by I02. No endpoint below is
advertised as live until I10/I11. Changes require coordinator review and retesting
of every dependent lane. Historical baseline: `benchmarks/results/2026-10-22-recommender-i01-baseline.md`.

## Identity and consistency

An authenticated account owns one shared in-memory profile across sessions.
Socket descriptors, browser claims and worker slots never establish account
authority. Admission changes that profile and independently schedules prediction
and persistence. A saved/failure event changes status only: it neither launches
prediction nor replaces recommendation DOM contents. A result can precede commit.
The UI must distinguish accepted/pending, saved, failed and uncertain outcomes.

The immutable population model may lag database commits. Prediction overlays the
current accepted profile and excludes the account's old population row. Preserve
the exact existing similarity/prediction/ranking semantics; freshness relaxation
does not authorize algorithm approximations. Model installation alone produces
no unsolicited result. These statements supersede older synchronous consistency
claims in the app requirements/design.

The server reserves a fresh 32-lowercase-hex epoch in a durable unique namespace
before listening. Operation IDs are epoch + 32-lowercase-hex random nonce (64
characters); browser entropy comes from WebCrypto, never Math.random. The epoch
prefix must match. IDs are never reused. Account revision, model generation and
job ID are canonical decimal **strings**, range 0..9223372036854775807, with no
leading zeros. Jobs/generations are positive except the control conventions
below. Do not round-trip these through JavaScript Number.

A global reactor revision clock advances for each new admission and each
effective discard mutation. This is stronger than per-account monotonicity and
prevents revision reuse after eviction/rehydration. Duplicate operations preserve
their original revision. Model installation never resets revisions. Exhaustion
rejects new work, drains and requires a fresh epoch; it never wraps.

## Portable Briev boundary

`protocol.bv` is the portable facade. `protocol_types.bv`, `protocol_values.bv`,
`protocol_codec.bv`, `protocol_events.bv`, `protocol_encode.bv`,
`protocol_policy.bv` and `worker_messages.bv` contain the implemented types and
pure codecs. `worker_framing.bv` is native-only. `admission_contract.bv` contains
data types for the future pure service, without placeholder implementations.
All paths here are relative to `examples/recommender/`.

`RatingCommand` carries server_epoch, operation_id, item_id and rating. Owner
comes from authentication. `ProfileVersion` adds account_id and revision.
`PredictionTag` adds model_generation, job_id and attempt. Types for accepted,
saved, failed, predicted and discarded events are distinct. The same codecs run
in native and WASM fixtures. Counters are incremented as checked decimal text.

I04 implements the pure entry points with the frozen records:

```text
profile_admit(AdmissionState, AdmissionContext, RatingCommand) -> AdmissionDecision
profile_hydrate(AdmissionState, HydratedProfile) -> Result<ProfileUpdate, AdmissionError>
```

`AdmissionContext` supplies authenticated owner/session generation, timestamp,
database identity and an already acquired `QueueReservation`. The reservation
covers profile/operation bytes and prediction/persistence slots. Rejected admission
releases it without changing state. `AdmissionDecision` returns explicit
New/Known/Rejected outcome plus state/actions. `ProfileAction` separates
ComputeProfile, PersistOperation, PublishEvent and ResolveReceipt. Completion
transitions return `ProfileUpdate`; save completion cannot emit ComputeProfile.
`ProfileSnapshot` retains both accepted ratings and the committed base needed
for discard/rebase, plus running/pending prediction ownership and last activity.
`OperationStatus` retains its reservation until the corresponding resources are
released. The pure terminal commit/discard transitions release that reservation;
failed work keeps it for explicit retry/discard. These records prevent
lifetime/accounting from disappearing between pure transitions and asynchronous
effects.

The frozen `ProfileAction` list has no deferred-queue action. I04 returns a
persistence request only for the head accepted operation. Later accepted
operations stay queued in pure state without an action; the allocated
persistence worker/coordinator serializes dispatch by account. Pure dispatch,
worker-tag binding and completion transitions reject any operation other than
the earliest unresolved one. Commit emits saved status and the next persistence
intent; the coordinator performs the returned effects in order. Prediction
invalidation remains in profile state and is drained by the reactor after
ordered writes settle, rather than being combined with persistence actions whose
execution order is unspecified.

`profile_admit` validates the current epoch, authenticated owner supplied by the
caller, checked timestamp, command payload, and an unused reservation covering
the profile/operation bytes and both worker slots before changing state. It
assigns a checked epoch revision and returns acceptance publication, prediction,
and persistence actions as separate values. Repeated owner/operation IDs with
the same payload return the original status without actions; a changed payload
conflicts. Profile ratings stay sorted and distinct-item counts do not increase
when an item is edited. Hydration cannot replace unresolved work and refuses to
replace a profile with a stale revision. If an idle profile was evicted, a new
edit requires hydration before admission.

Prediction start/completion transitions compare the full worker job tag and
current profile revision. An obsolete completion is not published; it clears
only its matching running job and requests work for the latest profile. Save
transitions update persistence status and the committed base. Commit emits only
saved status; it cannot request prediction. Discard requires the earliest
definitively failed operation, rebuilds the profile from committed ratings plus
remaining accepted operations, and requests prediction only when the effective
ratings change. The discard event follows tombstone commit. The reactor calls
idle eviction only after its configured idle interval; the pure transition also
requires all owner operations to be terminal and no prediction to be running or
pending.

The standalone behavior gate is `tests/fixtures/recommender/profile_admission_gate.bv`
(`run_profile_admission.sh`); it uses no database or sockets. Its invocation and
verification status are recorded in the dated I04 execution note.

## JSON and HTTP

Every document is UTF-8 JSON with numeric `v:1`; events and worker messages also
carry textual `type`. A rating command's endpoint supplies its kind. JSON is bounded
to 65536 bytes, duplicate keys in schema objects rejected, booleans strictly typed,
integers exact.
Unknown fields may be ignored for additive compatibility but confer no authority.
Wrong version/type/required fields are errors, never fabricated success.

| type | Fields in addition to v/type |
| --- | --- |
| command (no type field) | server_epoch, operation_id, item_id (0..1681), rating (1..5) |
| accepted | server_epoch, account_id, revision, operation_id, item_id, rating |
| saved | server_epoch, account_id, revision, operation_id |
| save-failed | saved identity, error, message, retryable |
| recommendations | server_epoch, account_id, revision, model_generation, job_id, attempt, cold_start, recommendations |
| discarded | original saved identity, profile_revision, ratings |

The executable codec is authoritative for the exact spelling of type values
(see `protocol_encode.bv`); consumers must call it rather than duplicate strings.
Ratings are sorted unique item/rating pairs, at most 1682. Recommendations contain
at most five unique item_id/score pairs, finite scores in [1,5], descending score
then ascending item ID. Cold-start results have no recommendations. Error codes
are bounded ASCII identifiers and messages are bounded to 1024 characters.

Future endpoints share one admission service:

| Endpoint | Semantics |
| --- | --- |
| POST /v1/ratings; live rating command | 202 accepted means admitted, not saved; same command and ID on fallback |
| GET /v1/state?token=… | asynchronous authoritative hydration, profile/version/status snapshot |
| POST /v1/operations/status | reconcile at most 64 IDs, with original durable receipts where known |
| POST /v1/operations/ID/retry | retry the existing operation, never create another revision |
| POST /v1/operations/ID/discard | explicitly resolve an eligible failed head, as below |
| POST /v1/logout | invalidate session, preserve account-owned accepted work |

Live transport is `/v1/live?token=…`; text commands decode as RatingCommand on
that authenticated rating-only channel, and server text replies use RatingEvent.
HTTP fallback resends the same command/ID. `/v1/login` and `/v1/register` use the
existing credential rules through asynchronous DB workers. Successful login
returns v:1, token, server_epoch and authoritative account identity; the browser
then hydrates `/v1/state`. A worker completing login must still match the waiting
session/request generation. These endpoints never claim a rating was saved.

**I09 browser binding detail (2026-10-23):** authenticated HTTP requests use the
same `?token=…` query convention as `/v1/state` and `/v1/live`; the token is not
added to a rating command. `/v1/login` and `/v1/register` accept the existing
`{username,password}` JSON body. Login returns
`{v:1,type:"authenticated",token,server_epoch,account_id,username}` and
registration returns `{v:1,type:"registered"}`. `POST /v1/ratings?token=…`
accepts exactly a v1 RatingCommand object; HTTP 202 returns the ordinary
`accepted` RatingEvent. Retry and discard use empty POST bodies at their
documented operation paths with the token query parameter; logout is likewise an
empty authenticated POST.

The state body is
`{v:1,type:"state",profile:{server_epoch,account_id,revision},username,ratings,model_generation,operations,next_after_revision,through_revision}`.
`ratings` is the complete accepted in-memory profile, sorted as defined above.
Each operation entry has `operation_id,item_id,rating,revision,status`; failed
entries also have `error,message,retryable`. `POST
/v1/operations/status?token=…` takes
`{v:1,operation_ids:[<up to 64 IDs>]}` and returns
`{v:1,type:"operation-status",current_server_epoch,operations:[…]}` in request
order. Each entry contains its `operation_id` and a `status`; unknown IDs have
`status:"unknown"`. These shapes let the browser reconcile without guessing at
database state or replaying an uncertain write.

Malformed input is 400, authentication 401, conflicting ID/epoch/state 409,
unsupported version 426, bounded-capacity refusal 429, unavailable service 503.
After cutover old unversioned writes receive an operation-required/version error;
they cannot silently mint IDs. Until cutover the existing legacy API is unchanged.

State hydration returns v:1/type:state, profile (ProfileVersion), username,
ratings, model_generation and an operations page. It does not synchronously
calculate recommendations; a later tagged result publishes independently.
Operation entries carry the original accepted fields, textual persistence phase
and error/message/retryable when applicable. The phase spellings are queued,
running, retry-wait, failed, uncertain, saved, discard-queued, discard-running,
discard-failed, discard-uncertain and discarded, corresponding one-to-one to
PersistencePhase. Return at most 64 status entries per page, ordered by original
admission revision. Stateless after_revision/through_revision decimal cursors
bound the current-epoch scan; return next_after_revision and through_revision
for continuation. Every page authenticates owner anew against cached session
authority. The full ratings/profile version accompanies each page; the browser
applies only its newest version and never treats pagination as an atomic snapshot.
Status queries return v:1/type:operation-status, current_server_epoch and operations
in the requested ID order, with explicit unknown entries. No read/status endpoint
starts a second prediction merely because a save finished. HTTP responses remain
bounded to 1 MiB; capacity errors cannot be replaced by silently truncated JSON.

Within an epoch exact owner/ID/payload duplicates return original revision/status;
changed payload is conflict. Retain all accepted current-epoch receipt identities
in bounded memory until epoch end. At its hard cap reject new admissions before
acceptance; do not evict receipt identities and accidentally admit a duplicate.
Durable receipts are retained for account lifetime, until account deletion.
There is no TTL in v1. Historical-epoch submissions are reconciliation-only:
return the original saved/discarded receipt if present; unknown requires explicit
conflict, authoritative hydration and deliberate resubmission with a new ID.
Never automatically replay unknown historical payloads.

## Ordering, failure and discard

Persistence is FIFO with one in-flight write per account. Prediction uses a
separate pool, one running plus latest pending prediction per account. Reserve
capacity before acceptance, publish acceptance, then schedule the independent
jobs. Any completion order is valid. A result publishes only if epoch, owner and
revision still match and the full issued job/generation/attempt tag matches.
An older model generation is allowed when it was issued for that still-current
profile. Saved acknowledgements never demote a newer profile revision.

`protocol_policy.bv` is the executable persistence phase/signal table. A definite
rollback allows retry; failure blocks the account's later durable writes.
An uncertain outcome requires receipt reconciliation under the account row lock,
which waits for any old transaction, before retry or discard can be decided.
Exhaustion remains visible and blocks FIFO. Retry is bounded and preserves ID.

Discard is a separate state machine. Persist a discarded receipt/tombstone in
FIFO order before releasing the failed head. A discard retry cannot reinsert the
original rating. Rebuild the accepted profile from durable base plus remaining
accepted operations, preserving later edits; advance revision and request a new
prediction only if the effective profile changes. Publish authoritative ratings
and new profile_revision with the original operation identity. Already committed
operations cannot be discarded: return conflict and require a compensating edit.

The persistence transaction locks the account row FOR UPDATE, looks up the receipt,
checks identical payload, and atomically commits rating upsert + receipt + durable
population revision. Announce saved only after successful COMMIT/ReadyForQuery.
Hydration takes the corresponding account FOR SHARE lock so an old uncertain
writer cannot be bypassed after restart. Worker DB identity is database/schema/
epoch (excluding population revision). Model identity includes the full cache
identity including population revision. Epoch/schema mismatch stops jobs and
invalidates cached authentication; account IDs are never reused by the app.
Operator reseed/restore requires restart and fresh namespace validation.

## Sessions and bounded lifetime

Login and periodic refresh reconcile cached identity; ordinary rating/read/push
paths perform no identity SQL. Reconciliation defaults to 300 seconds. External
revocation therefore has bounded eventual detection, not immediate detection
during DB outage. Discovered deletion invalidates every owner session and reports
pending work truthfully. Session generations monotonically invalidate callbacks.
Logout invalidates the token; already accepted work remains account-owned.

Evict only idle committed profiles with no jobs/reservations. Pending profiles
remain owned until resolution. Browser queues are memory-only; pending logout or
reload requires deliberate leave/retry UI. beforeunload is best effort. A crash
may lose uncommitted accepted memory, which must be disclosed and reconciled.
Shutdown stops admissions, drains for ten seconds, reports unresolved outcomes
as uncertain, terminates/reaps children and relies on durable receipts on restart.

## Worker framing and model ownership

Frames are magic BRV1 (u32 big endian 1112692273), u32 big-endian byte length,
then 1..65536 UTF-8 JSON bytes. Partial input is retained, adjacent frames consumed
individually. Bad magic/length/JSON closes that worker channel, never allocates
an unbounded body. `worker_frame_size`, `worker_frame_encode` and
`worker_frame_decode` implement this framing; nonblocking partial I/O is I05.

`worker_messages.bv` validates the request/reply kind and payload in addition to
the full tag: server_epoch/account_id/revision/job_id/attempt/model_generation.
Requests: predict, persist, hydrate, receipt, discard, install, shutdown, login,
register. Replies: started, result, saved, save-failed, hydrated, receipts, ready,
stopped, authenticated, registered, error. Control owner/revision are zero; authenticated
work uses positive owner. I/O generation is zero; model jobs require positive
generation. An error preserves its issued tag. Parent checks the issued-job
registry, full tag and ownership before publication. A valid frame alone has
no authority. Receipt batches contain at most 64 unique IDs.

All worker bodies use the event-style top-level fields from `protocol_fields`,
plus job_id, attempt, model_generation and an object `payload`:

| Kind | Payload |
| --- | --- |
| predict | ratings, lambda_milli (integer 0..1000; 500 is the default) |
| persist | operation (v1 command object), timestamp (canonical decimal string), database_identity |
| hydrate | database_identity |
| receipt | operation_ids, database_identity |
| discard | original operation (v1 command object), operation_id matching that command, timestamp matching the accepted operation (canonical decimal string), database_identity; tag is original operation's profile version |
| install | generation matching tag, absolute path, identity, bytes |
| started | role and current server epoch; required before parent admits work |
| shutdown | deadline_ms (canonical monotonic-clock decimal string) |
| login/register | username, password strings; native IPC only, never diagnostic logs |
| result | complete recommendations event with matching full tag |
| saved/save-failed | complete corresponding event with matching profile |
| hydrated | username, ratings |
| receipts | current_server_epoch matching tag, operations |
| ready | generation matching tag, identity |
| stopped | drained:true; incomplete shutdown uses error |
| authenticated | account_id, username, ratings |
| registered | account_id, username |
| error | error, message, retryable |

A receipt entry has operation_id and status unknown/saved/discarded. Known
entries additionally carry original server_epoch/account_id/revision and the
item_id/rating payload, allowing exact conflict checks. Their owner must match
the query owner; historical original epochs are retained. Parent correlates the
returned ID set and payloads to its issued request, including saved/failure IDs.
Hydration and receipts can use revision zero before a current profile is assigned;
prediction and persistence commands require a positive admitted revision.

Workers are persistent, with separate bounded DB/prediction pools. I08 provides
the bounded per-owner prediction queue, fair dispatch and model-generation
leases; I10 wires it into reactor admission/publication. I05 handles partial writes/reads, EOF,
crash, hang, timeout, bounded restart/backoff, reaping and parent death. Children close inherited parent DB
descriptors without issuing a parent-protocol termination. No per-click fork.

Implementation note (2026-10-22): `predict` carries `lambda_milli` so the
persistent child executes the same configured shrinkage value as the active
profile engine; the integer wire representation avoids floating-point JSON
ambiguity. `operation_store.bv` installs retained,
account-owned save/discard receipts and serializes them with rating updates under
an account-row lock. I07's `discard` payload includes the original command and
accepted timestamp so a restart can create the same tombstone without volatile
worker state. `persistence_worker.bv` acknowledges saves only after commit and
returns uncertain outcomes for fresh-connection receipt reconciliation.
`worker_io.bv` provides parent-side
nonblocking BRV1 send/receive steps, retained partial-write suffixes, bounded
preallocated receive storage, `MSG_NOSIGNAL`, terminal EOF/error handling and
one-frame extraction while preserving buffered suffixes. `worker_lifecycle.bv`
provides bounded worker counts, nonblocking wait/reap supervision, timeout
kill-and-reap, parent-death guard/descriptor-close helpers, and immutable
generation slots with explicit reader leases. `worker_pool.bv` launches
persistent SOCK_STREAM children, verifies the startup role/epoch handshake,
and installs a checksum-validated model image plus the exact I06 prediction
engine before acknowledging readiness. `prediction_worker.bv` validates the
configured shrinkage value and returns the full recommendations event. The
process fixture verifies partial reads/writes, bounded buffers, pre-install
rejection, repeated prediction through one worker workspace, generation swap,
graceful shutdown, crash/restart, timeout, malformed-frame isolation and no
zombies. The pure queue gate covers coalescing, fair owner progress, full-tag
stale suppression, epoch rejection, worker-loss retry, terminal errors and
owner-capacity reuse. The queue bounds worker and owner counts and permits
owner removal only after running and pending work clear. The generation gate
verifies worker/job reader holds, capacity refusal, acquire-before-release
replacement and reclamation. A live PostgreSQL
advisory-lock waiter remains blocked while the prediction process completes.
The imposed host fd-limit experiment was unreliable and is not claimed as a
passing gate; socketpair setup errors are rejected before a child exists. I07
owns durable DB work; I10 wires both pools into reactor admission and
publication.

Models are immutable descriptors (generation, absolute Linux path, full identity,
byte size) using the existing snapshot validation/checksum. Workers acknowledge
installation before receiving jobs. Each issued job retains a reader lease until
terminal completion or child reaping. Keep at most four generations; defer/refuse
refresh when leases prevent reclamation. Installation does not recompute profiles.
The baseline's substantial RSS growth requires physical residency and idle-worker
recycling/plateau gates; logical queue limits alone are insufficient.

## Initial configuration contract

Names are environment variables; I05/I10 implement checked parsing and startup
diagnostics. These conservative defaults are resource policy, not performance
claims. I16 tunes only after correctness and controlled measurements.

| Variable | Default / accepted range |
| --- | --- |
| PREDICTION_WORKERS, PERSISTENCE_WORKERS | 2 each / 1..16 |
| PROFILE_LIMIT | 1024 / 1..100000 |
| PENDING_PER_OWNER | 128 / 1..1024 |
| PENDING_GLOBAL | 8192 / 1..131072 |
| RECEIPT_LIMIT | 131072 / 1..1048576 |
| RECEIPT_BYTES | 67108864 / 65536..536870912 |
| MODEL_GENERATIONS | 4 / 2..8 |
| WORKER_TIMEOUT_MS | 120000 / 1000..600000 |
| WORKER_RETRIES | 3 / 0..10 |
| IDENTITY_REFRESH_SECONDS | 300 / 1..3600 |
| PROFILE_IDLE_SECONDS | 900 / 1..86400 |
| SHUTDOWN_DRAIN_MS | 10000 / 0..120000 |

Retry backoff is bounded 100 ms..10 s. IPC body limit is 65536 bytes; model bytes
are bounded to 512 MiB per validated descriptor. Capacities are checked jointly
before acceptance, including retained bytes, not merely record counts. Existing
refresh/cache configuration remains in force. Timeout yields visible failure or
uncertainty, never a fake successful result.

## I03/I09 asynchronous browser ABI

I03 adds general APIs in `lib/std/web/fetch.bv`/`lib/glue/web/web.js`, preserving
the synchronous ABI. No Promise crosses a String-returning WASM function.

```text
http_async_start(url, method, body, options_json, event_name) -> Int
http_async_status(handle) -> Int
http_async_http_status(handle) -> Int
http_async_body(handle) -> String
http_async_error(handle) -> String
http_async_cancel(handle) -> Void
http_async_release(handle) -> Void
```

Positive handles are monotonic and never reused within a WASM instance. Start
returns -1 invalid configuration, -2 unsupported method, -3 invalid URL,
-4 capacity/exhaustion, -5 unavailable host capability. Options: timeout_ms
1..120000 (default 30000), max_bytes 1..1048576, content_type. Bound live handles
to 32 and total retained response bytes to 32 MiB. Status: 0 unknown/released,
1 pending, 2 complete, 3 failed, 4 cancelled. HTTP status is zero before headers.
HTTP error responses are complete with their status/body, not transport failure.
Use a bounded streaming UTF-8 reader; reject overflow before retaining excess.

Terminal completion/failure dispatches the named event once. Timeout fails and
notifies once. Cancel only pending work, makes it terminal/cancelled and suppresses
completion. Release is idempotent, cancels work and suppresses even queued
callbacks. Closures verify map-entry identity; the app also checks auth generation.
Body is available only on complete; callers copy it and release. Error is available
only on failure. Repeated reads do not start work. No automatic write retry.
Unknown/pending body/error access returns an empty string. Complete/cancelled
handles keep their terminal status until release. Cancelling a terminal handle
does nothing. Handles range 1..2147483647; exhaustion is capacity refusal, never
wraparound. Completion dispatches `CustomEvent(event_name, {detail: handle})`;
Briev handlers may inspect their owned handle statuses rather than depend on
event-detail plumbing. Event names are nonempty ASCII identifiers of at most 64
characters. Supported methods are GET, HEAD, POST, PUT, PATCH, DELETE and OPTIONS;
GET/HEAD require an empty body. URLs resolve against document.baseURI and must
use HTTP(S). Preserve browser CORS and same-origin credential defaults. Transport
error codes are timeout, network, response-too-large, invalid-utf8 and host-error;
none implies that a write failed to commit. Reconciliation owns that decision.
I03 exposes general secure-random bytes/hex through stdlib for nonce generation.
I09 handles pending UI immediately, reconciliation and same-ID live/HTTP fallback.

## File and resource allocation

The coordinator alone owns shared server files, app.rbv integration, this contract,
specification updates, BUGS.md and existing shared runners. New lane modules and
fixtures are disjoint. This allocation authorizes no agents by itself.

| Task | Primary modules / fixtures | Isolated resource suffix |
| --- | --- | --- |
| I03 | std/web/fetch.bv, glue/web/web.js, std/web/random.bv; async_http_* fixtures | i03, ports 18103/18203 |
| I04 | profile_state.bv, admission.bv; profile_admission_* fixtures | i04, no DB |
| I05 | worker_pool.bv, worker_io.bv, worker_lifecycle.bv; worker_pool_* fixtures | i05, ports 18105/18205 |
| I06 | active_profile.bv, prediction_scratch.bv; active_profile_* fixtures | i06, exclusive timing |
| I07 | operation_store.bv, persistence_worker.bv; operation_store_* fixtures | i07, briev_recommender_i07 |
| I08 | prediction_worker.bv, model_generations.bv; prediction_pool_* fixtures | i08, briev_recommender_i08 |
| I09 | browser_profile.bv, browser_operations.bv; browser_pending_* fixtures | i09, ports 18109/18209 |
| I10–I13 | coordinator shared-file wiring and integration fixtures | i10..i13, unique DB/ports per task |
| I14 | responsiveness_native_* fixtures/runners | i14, briev_recommender_i14 |
| I15 | responsiveness_browser_* fixtures/runners | i15, briev_recommender_i15, 18115/18215 |
| I16 | benchmarks/recommender_responsiveness, results | i16, exclusive DB/CPU timing |
| I17 | regression runners, architecture and final handoff | serialize shared gates |

Every lane uses `target/recommender-Ixx/` output, private CACHE_PATH and IPC
directory. Never run fixed-reset schemas concurrently. Shared cargo targets are
serialized. I01 uses briev_recommender_i01 and ports 18082/18083; its services
are stopped and evidence retained. All further tasks retain the declared AND
dependencies in tasks-improvement.md. The I02 native/WASM codec, framing and
policy fixtures are required compatibility gates for subsequent changes.
