# Briev `main` compatibility — 2026-10-25

This branch aligns the recommender with the current compiler/stdlib naming and
makes the native service compile against current `main`.

## Renames

- `Matrix` → `FloatMatrix`
- `Vector` → `FloatVector`
- `IntVec` remains unchanged

## Status

- Browser `app.rbv`: builds and loads with current `brievc` (zero page errors).
- Server `server.bv`: `brievc check` passes and `brievc build` links the native
  executable.
- Fixtures: the seven `tests/fixtures/recommender/*.bv` files still used the
  old `Vector` spelling; they now use `FloatVector`.
- `run_active_scratch.sh`: PASS.
- `run_active_profile.sh`: PASS at `-O0` and at `-O3` without LTO; the
  harness-exact `-O3 -flto` binary segfaults (compiler bug, not a guard).
- `run_worker.sh`: runs, but generation 2 loses the installed state in the
  current compiler; the same gate passes with the app's original compiler.
- Runtime gates that need PostgreSQL, MovieLens 100K, or Playwright have not
  been run on this branch.

## Compatibility changes

The service now states every callee precondition it relies on as an explicit
`when !(...) { trap; };` guard. The guard families cover:

- reactor row access and socket file descriptors
- vector/ivec indexing and CSR/matrix capacities
- PostgreSQL result rows/columns
- system-call constants and buffer slices
- rating-population begin/end and mean accessors
- profile/imputation indexes

Two compiler fixes were required and are carried by the companion Briev
change:

1. Destructuring `let` no longer falls back to `Int` when tuple inference
   fails; the inference error is propagated (the fallback hid the real mismatch).
2. `Type { field: value }.field` is reduced to `value` by the proof engine, so
   struct-literal arguments (`Socket { fd: fd }`, `ByteBuf { ... }`) discharge
   bounds already guarded by the caller.

`std/posix/syscall.bv` on current `main` does not export `SYS_KILL`,
`SYS_PRCTL`, or `SYS_SOCKETPAIR`; the worker modules define those three
constants locally. Migrate them to the stdlib import once it exports them.

## Reproduction

```sh
BRIEV_STDLIB=/path/to/briev/lib/std brievc check examples/recommender/server.bv \
  --stdlib-path /path/to/briev/lib
BRIEV_STDLIB=/path/to/briev/lib/std brievc build examples/recommender/server.bv \
  --stdlib-path /path/to/briev/lib --out target/recommender-demo
BRIEV_STDLIB=/path/to/briev/lib/std brievc build examples/recommender/app.rbv \
  --stdlib-path /path/to/briev/lib --split --out target/recommender-web
```
