# Briev `main` compatibility — 2026-10-25

This branch aligns the recommender with the current compiler/stdlib naming:

- `Matrix` → `FloatMatrix`
- `Vector` → `FloatVector`
- `IntVec` remains unchanged

## Status

- Browser `app.rbv`: builds and loads with current `brievc` (zero page errors).
- Server `server.bv`: not yet clean. After the rename it reports 119
  type/contract errors:
  - 1 type mismatch
  - 118 contract failures in reactor row access, vector/ivec indexing,
    CSR/matrix capacities, PostgreSQL row access, system-call constants,
    buffer slices, and rating-population accessors.

The remaining failures are app-side proof/bounds gaps, not missing stdlib
modules. They must be fixed with explicit guards or explicit dynamic
boundaries; do not weaken stdlib contracts.

## Next

Add guards by family, then run:

```sh
brievc check server.bv
brievc build server.bv
```

until the server checks and links, followed by the existing PostgreSQL /
MovieLens / WebSocket gates.
