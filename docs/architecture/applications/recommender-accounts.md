# Recommender account service

The task-11 account service uses the task-10 schema and Briev PostgreSQL client.
Its public Account has only id and username: neither cleartext passwords nor
stored hashes are returned in account/state results.

`register(conn,username,password)` rejects empty/whitespace-only credentials.
Whitespace detection includes ASCII controls and Unicode White_Space. Meaningful
inputs retain their exact bytes, including surrounding whitespace. Passwords
are stored as `fnv1a32:<unsigned decimal>` using FNV-1a over UTF-8 bytes; a 64-bit
intermediate and a 32-bit mask avoid signed overflow. This unsalted demo scheme
provides NO real credential security. Another storage scheme requires explicit
migration; existing plaintext or other hashes are not silently reinterpreted.

One parameterized INSERT ON CONFLICT(username) DO NOTHING RETURNING id,username
arbitrates duplicate registrations atomically. A zero-row return means
account-exists; a server/transport error stays database, with its PgResult detail.
No check-then-insert race or credential interpolation is involved.

`login(conn,sessions,username,password)` matches the exact username and hash with
bound parameters. A match issues a token and returns LoginResult containing the
public account, token, and updated SessionStore. The single-process server MUST
retain `result.sessions` before serving the next request. The old value is not
silently mutated. Failed auth/SQL/entropy returns an empty token and the unchanged
store; failed credential matches use the same auth-failed category.

Tokens encode 16 kernel-random bytes as 32 lowercase hexadecimal characters.
The pure-Briev file/syscall path reads /dev/urandom, handles partial reads/EINTR,
and frees/closes its resources on all paths. Token collision retries never
overwrite an existing binding; repeated collisions or entropy failure fail
without changing state. Tokens are table keys, never encoded account IDs.

SessionStore is explicit process-local value state. Tokens last for the lifetime
of that retained store; restarting the server starts an empty store. Persistent
credentials and ratings survive and can establish fresh sessions. Session
expiration and durable session storage are not part of the current API. `POST /v1/logout`
(also `/logout`) requires the token query parameter, revokes only that token,
and returns the versioned `logged-out` envelope. A missing, invalid or already
revoked token returns the ordinary authentication error. The reactor owns one
authoritative store; request handlers must not keep stale copies as independent
authorities. Each live channel is bound to its exact token and receives a policy
close when that token is revoked, while other sessions for the account remain
valid. Service connections are used idle/autocommit by the server; these APIs do
not commit caller-owned transactions.

`account_state(conn,sessions,token)` resolves the owner from the session table,
then performs one account-filtered LEFT JOIN of identity and ratings. It returns
AccountState with public AccountResult and ordered AccountRating values
(item_id,rating,timestamp). An empty account is successful with zero ratings.
Unknown tokens and deleted accounts fail auth; a database failure retains its
SQLSTATE and is not misclassified as failed credentials. Invalid stored rows
produce an error, never a partially successful state or another owner's data.

As confirmed by the human, task 12 composes recommendations from this SAME
authenticated owner's engine row. Task 11 neither computes recommendations nor
returns a fabricated empty recommendation cache for warm accounts. HTTP and live
routes must reuse the resolved owner for writes, recommendations, and delivery.
Account IDs are not baseline user indices: task 12 must map them to appended
engine rows explicitly rather than indexing the 943 baseline rows with an ID.

Login and registration run through the persistence child. Login returns the
owner's ratings and a generated opaque token; the reactor adopts that exact
token and hydrates its process-local admission profile before responding. The
reactor validates later HTTP and WebSocket requests from that in-memory session
store. Profile state reads use the hydrated cache. Operation-status requests
query durable receipts through the persistence child, so an account-row lock
does not block the reactor.

Server startup applies the additive `rating_operation_receipts` table migration
after creating the base account/rating schema. Each accepted rating is persisted
with its idempotency receipt in one account-locked transaction; a restart can
reconcile an uncertain client operation without replaying an unverified write.

Native gates: tests/fixtures/recommender/run_accounts.sh. Dedicated schemas
briev_accounts_gate and briev_account_state_gate isolate the fixtures from public
baseline data. The corpus checks 144 credential combinations, all whitespace
classes, FNV vectors, duplicate/persistence/login cases, explicit session state,
token hex endpoints, and 120 generated account-isolation cases plus error paths.
