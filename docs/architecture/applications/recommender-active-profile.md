# Exact active-profile worker engine

`examples/recommender/active_profile.bv` implements I06 independently of reactor
admission, PostgreSQL and process scheduling. I08 connects it to prediction
workers. The serial `server_model.bv` path remains its numerical reference.

## Integration and lifetime

After a worker installs a validated `ServerModel`, call
`active_engine_new(model, generation, byte_limit)`. It returns
`Result<ActiveProfileEngine,String>` and refuses invalid generations, unsupported
dimensions, insufficient memory budgets and allocation failure. The maximum
budget is 512 MiB; the real 943-user/1682-item model uses 3,645,280 bytes.
The caller chooses a budget consistent with its pool's total memory allowance.

`active_engine_predict(engine, request, lambda)` consumes I02's typed
`PredictionRequest` and returns `Result<RecommendationResult,String>`. It
requires valid job tags, the installed model generation, a finite lambda in
[0,1], and unique, ascending, in-range items with integer ratings in [1,5].
The result preserves epoch, owner, revision, generation, job ID and attempt.
Below five distinct ratings it returns cold-start and no recommendations.
Errors never masquerade as a cold-start or successful empty calculation.

The engine borrows its model and the current request's ratings. One worker
evaluates one request at a time; concurrent evaluations must use different
engines. All large arrays and transient peer cursor fields are reused. Results
contain independent ranked records, so later jobs do not overwrite earlier
results. Callers own request/result lifetimes and bound their queued results.
After the last job, call `active_engine_free(engine)` once, then release the
borrowed model. On model replacement, finish/cancel the current job and release
the old engine before freeing its model; build a new engine for the new
generation. I08 owns dispatch, cancellation and stale publication rejection.

`active_profile_prepare/build/scores` expose the borrowed workspace for exact
reference gates. Their contents last until the next evaluation; the public
worker result does not borrow these arrays.

## Calculation and correctness

The model's CSR, means and served item matrix remain immutable. The account-ID
mapping identifies its old snapshot row, which is excluded from every user
candidate and imputation column. The active row is represented by reusable
dense lookup and sorted sparse buffers. It contributes last in imputation sums,
as it does when the reference appends a replacement row to the population.

Base Pearson similarities between surviving population users depend only on
their observations and true means. Excluding another row changes neither fact.
Empty rows have zero base similarity regardless of the changed global fallback.
The workspace therefore memoizes this matrix once per installed model. It
computes active base similarities once per job and active imputed entries once
per catalogue item. Served user similarities still visit each pair's original
observed union in ascending order; no dense-key substitution or approximate
neighbor search changes the equations.

User prediction gathers the original ascending user-column candidates with the
old owner excluded. Item prediction uses the immutable served item similarities
and item means, matching the current server's frozen-cache semantics. Both use
the existing kNN selector with a cleared, reused marker prefix. Selection remains
by descending signed similarity, retaining the original traversal order for
ties. The fused, clamped scores must be finite. Ranking excludes current rated
items, sorts scores descending, and preserves ascending item IDs for ties.

Float arrays use the reflected physical width; integer arrays begin at an
eight-byte-aligned offset. Dimension checks bound every size multiplication
before allocation, and one owned block bounds all large scratch storage.

## Verification and numerical tolerance

Run `BRIEVC=... CACHE_PATH=... bash tests/fixtures/recommender/run_active_profile.sh`.
Without CACHE_PATH, the runner executes only isolated edge cases. With a retained
real snapshot, it compares every user similarity, every finite catalogue score
and exact ranked IDs/order across repeated 0/4/5/20/100-rating profiles and an
existing-owner exclusion case. Zero/four-rating calculation is forced by the
reference fixture; the public worker API correctly bypasses it as cold-start.
Other cases cover empty populations, empty users/items, zero variance, negative
similarities, ties, rated-item exclusion, complete catalogues, lambda endpoints,
profile edits, duplicate rejection, budget refusal, generation mismatch, account
switches, retained results and reuse/alignment of storage.

Served PCCs retain the existing absolute 1e-6 tolerance. Normalized FP32 scores
use 1e-6 absolute plus 1e-5 relative tolerance: accumulation/reassociation and
normalization amplify sub-ULP PCC differences. This relative allowance is below
the standard gamma_943 bound of approximately 1.1e-4 for an FP32 reduction of
943 terms. It is an error budget for the tested geometry, not a proof of a
uniform bound for arbitrarily ill-conditioned normalization. Ranked IDs/order
are checked exactly, without a tolerance. The real gate observed PCC error at
most 5.96e-8 and clamped score error below 1e-5.

A separate gate warms the workspace, evaluates a 100-rating profile another
100 times and requires resident growth at most 256 pages. The measured growth
was one page. It isolates the calculation from caller-owned request/result
retention. Results and timing provenance are archived under
`benchmarks/results/recommender-i06/`; these are engine measurements, not I16
browser/load acceptance claims.
