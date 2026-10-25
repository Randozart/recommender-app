# Recommender persistence

Task 10 uses the Briev PostgreSQL client, without a host-language database
adapter. `examples/recommender/store.bv` owns schema creation and account rating
writes; `bootstrap.bv` owns baseline loading; `baseline_population.bv` reconstructs
the engine's sparse population.

Dataset identities are separate from login accounts. Baseline rows use zero-based
user indices 0..942 and item indices 0..1681 in `baseline_ratings`; account ratings
use the foreign-key account ID and an account/item primary key in `ratings`.
Account services must resolve identity from authentication before calling
`store_rating_upsert`; a baseline user index is never an account ID.

Bootstrap owns an idle connection's READ COMMITTED transaction. It inserts the
baseline marker if absent, locks it with SELECT FOR UPDATE, and checks done only
after acquiring the lock. Concurrent startup loaders therefore serialize. A done
marker skips source-file access. Otherwise the loader replaces incomplete rows,
parses lines with strict range/overflow validation, and inserts bounded batches
of 64 records using parameters. Duplicate keys use the last valid source record,
including across batches. Empty or unreadable sources and SQL failures roll back
rows and marker together. Only successful insertion marks done and commits.
Transport failures require a fresh connection; a lost commit response has an
unknown outcome, resolved by the next locked-marker check.

Population reconstruction owns a read-only REPEATABLE READ transaction: marker,
count, and ordered keyset pages share one snapshot. Temporary arrays feed
`pop_build`, producing both user and item orientations with all 943 user slots.
Successful results transfer population ownership to the caller (`pop_free`);
errors free temporary arrays, roll back, and return the original PgResult.

Rating upsert is one parameterized INSERT ON CONFLICT at (account_id,item_id).
It replaces rating and timestamp without touching another account/item. It does
not create or finish transactions: an idle connection autocommits; an existing
transaction stays caller-owned. Input bounds and database CHECK/FK constraints
both protect the stored representation.

The receive-buffer invariant is `0 <= len <= cap`: memory initialized by an
external writer must be published through `buf_received` before bounded readers
inspect it. This returns a view of the same allocation, not a second owner;
free exactly once. `pg_read_msg` publishes completed header/payload lengths so
SQLSTATE and error messages are decoded. Wrong-side Result unwraps trap; successful
unwraps preserve their actual payload, including objects.

Native gates and their runner live in `tests/fixtures/recommender`. They use
separate named test schemas; full-baseline mode reads the public baseline only.
Schema creation is repeatable creation, not a migration system: existing layouts
must be migrated explicitly.