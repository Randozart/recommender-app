# Recommender system map

This guide gives four views of the current implementation: module structure,
runtime ownership, the rating-to-recommendation path, and model startup/refresh.
The source of truth is `examples/recommender/`; protocol and lifetime details
remain in the focused architecture notes alongside this file.

## 1. Components and dependencies

The arrows below mean “imports or directly uses.” The browser is a separate
compiled target. The native entry imports the server coordinator; most other
modules are shared only within their own target.

```mermaid
flowchart TD
  subgraph Browser[Browser target: app.rbv]
    UI[app.rbv\nUI + client state + async requests]
    BCat[browser_catalogue.bv\nmovie pages]
    BProf[browser_profile.bv\nprofile helpers]
    Proto[protocol*.bv\ntypes, codecs, events, policy]
    UI --> BCat
    UI --> BProf
    UI --> Proto
  end

  subgraph Server[Native server target: server.bv]
    Entry[server.bv\nconfiguration + boot]
    Loop[server_loop.bv\nHTTP/live poll sweep]
    State[server_state.bv\nauthoritative service state]
    IO[server_io.bv\nHTTP/socket reads and writes]
    Reactor[reactor.bv\nlistener + connection slots]
    API[server_api.bv\nroutes + response helpers]
    Sess[accounts.bv + sessions.bv\ncredentials + process-local tokens]
    Admission[admission.bv + profile_state.bv\naccepted operation state]
    Store[store.bv + operation_store.bv\nPostgreSQL schema/writes/receipts]
    Bootstrap[bootstrap.bv + udata.bv\nbaseline import]
    Model[server_model.bv + model_types.bv\nserved model + persistence snapshot]
    Engine[cf_engine.bv + cf_prepared.bv\ncollaborative filtering]
    Active[active_profile.bv + prediction_scratch.bv\nper-owner workspace]
    Workers[worker_pool.bv + worker_* + *_worker.bv\nchild lifecycle + framed messages]
    Catalogue[movie_catalogue.bv\ntitle data]
    Trace[trace.bv\noptional timing trace]

    Entry --> Loop
    Entry --> Bootstrap
    Loop --> State
    Loop --> IO
    IO --> Reactor
    State --> API
    State --> Admission
    State --> Sess
    State --> Workers
    State --> Model
    API --> Catalogue
    API --> Trace
    Sess --> Store
    Bootstrap --> Store
    Model --> Store
    Model --> Engine
    Active --> Model
    Active --> Engine
    Workers --> Active
    Workers --> Model
    Workers --> Store
    Workers --> Admission
  end

  Browser -. HTTP / WebSocket JSON .-> Loop
  Loop --> PG[(PostgreSQL)]
  Bootstrap --> Files[(MovieLens u.data / u.item)]
  Model --> Cache[(snapshot file)]
  Workers --> Child[Linux child processes]
```

`cf_engine.bv` is the numerical reference implementation. It builds sparse
user/item rating populations, means, imputed values, Pearson similarities,
predictions and rankings. `active_profile.bv` reuses a worker-local workspace
for one account's prediction jobs; `server_model.bv` remains the serial served
path and owns snapshot loading/saving. The module names and current integration
are described in `recommender-server.md` and `recommender-active-profile.md`.

## 2. Runtime topology and ownership

```mermaid
flowchart LR
  Browser[Browser tab\napp.rbv compiled to WASM]
  Host[Generated JS host\nfetch + WebSocket + event handles]
  Reactor[Native server\nsingle reactor / authoritative ServerState]
  Persist[Persistence child\none PostgreSQL connection]
  Predict[Prediction child\nmodel generation + scratch workspace]
  DB[(PostgreSQL\naccounts, ratings, baseline, receipts)]
  Cache[(Atomic model snapshot)]
  Data[(MovieLens files)]

  Browser <-->|async HTTP + live JSON frames| Host
  Host <-->|HTTP / WebSocket| Reactor
  Reactor <-->|bounded framed IPC| Persist
  Reactor <-->|bounded framed IPC| Predict
  Persist <-->|SQL| DB
  Reactor -->|startup / serial reads| DB
  Predict -->|validated model artifact| Reactor
  Reactor -->|fork refresh builder| DB
  Reactor --> Cache
  Reactor --> Data
```

The reactor owns socket slots, live-session ownership, session tokens, admitted
operations and the currently served state. It does not wait for a database save
or prediction on the interactive rating path: it sends bounded worker messages,
then polls for replies during later sweeps. There is one persistence child and
one prediction child in the current integration. Each worker channel allows one
outstanding request; busy admission is rejected for retry rather than silently
queued at the socket boundary. Refresh building is separate: a forked builder
produces a complete replacement snapshot while the old model continues serving.

## 3. Rating, save and recommendation data flow

```mermaid
sequenceDiagram
  autonumber
  actor User
  participant UI as Browser app
  participant S as Reactor / server state
  participant P as Persistence child
  participant DB as PostgreSQL
  participant W as Prediction child
  User->>UI: Select movie and rating
  UI->>UI: Create operation ID; paint rating pending
  alt WebSocket is open
    UI->>S: rating command + operation ID
  else no live channel
    UI->>S: HTTP fallback with same operation ID
  end
  S->>S: Authenticate token; validate and admit operation
  S-->>UI: accepted event / HTTP 202
  par Save
    S->>P: persist tagged operation
    P->>DB: account-locked upsert + durable receipt
    DB-->>P: committed receipt or failure/uncertain result
    P-->>S: saved / failed / uncertain event
    S-->>UI: save status event
  and Predict
    S->>W: profile revision + ratings + model generation
    W->>W: active-profile calculation and ranking
    W-->>S: tagged prediction result
    S->>S: Reject stale revision/generation result
    S-->>UI: recommendation event
  end
  UI->>UI: Apply prediction only for current profile revision
```

The UI has separate save and prediction state. A save confirmation changes the
operation status but does not trigger another recommendation render. If a
transport failure leaves the save outcome uncertain, the browser asks for
operation status; it does not blindly replay the write. The operation ID and
receipt make a confirmed retry idempotent. See `recommender-frontend.md`,
`recommender-accounts.md`, and `recommender-responsiveness-contract-v1.md`.

## 4. Startup and model refresh

```mermaid
flowchart TD
  Start[server.bv starts] --> Config[Read PORT, limits, lambda, refresh interval]
  Config --> Connect[Connect to local PostgreSQL]
  Connect --> Schema[Create base schema and receipt table]
  Schema --> Bootstrap[Lock baseline marker; load u.data if needed]
  Bootstrap --> Catalogue[Load and validate 1,682 ordered movie titles]
  Catalogue --> Model[Read one consistent DB snapshot; build model]
  Model --> Snapshot{Matching snapshot cache?}
  Snapshot -->|yes| Reuse[Reuse validated complete model image]
  Snapshot -->|no| Build[Build model from DB population]
  Build --> Save[Persist complete snapshot atomically]
  Reuse --> Listen[Open reactor listener]
  Save --> Listen
  Listen --> Workers[Start persistence and prediction children]
  Workers --> Serve[Repeated bounded socket/worker sweep]

  Serve --> Refresh{Refresh requested or due?}
  Refresh -->|no| Serve
  Refresh -->|yes| Fork[Fork isolated snapshot builder]
  Fork --> Continue[Keep old model serving]
  Continue --> Result{Child succeeded and artifact validates?}
  Result -->|no| Keep[Keep old model; allow retry]
  Result -->|yes| Install[Install new model generation]
  Install --> Recompute[Refresh/push owners over later sweeps]
  Keep --> Serve
  Recompute --> Serve
```

Bootstrap and initial model construction happen before listening. During an
explicit or periodic refresh, the reactor keeps serving the installed model;
only a successfully completed and validated artifact replaces it. Model
identity includes the database/schema revision and epoch, so startup reuses a
cache only when it belongs to the same population. See `recommender-persistence.md`
and `recommender-server.md` for transaction, cache and failure guarantees.

## 5. A quick way to read the code

For a request path, start at `server.bv`, follow `server_loop.bv` into
`server_state.bv`, then inspect the route/helper module it calls. For a rating,
follow `server_dispatch_admission` and `server_worker_poll` in
`server_state.bv`, then the matching worker (`persistence_worker.bv` or
`prediction_worker.bv`). For recommendation math, start at `cf_engine.bv`; for
the reusable active-profile implementation, start at `active_profile.bv`.
For browser behavior, start at the `txn` handlers in `app.rbv` and follow the
`client_*` helpers they invoke.
