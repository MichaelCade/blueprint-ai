# SurrealDB with Kasten — consistent dump on a keeper PVC

Back up a **single-node SurrealDB** (SurrealKV storage engine) deployed with the official Helm
chart. A small **keeper** pod in the same namespace runs `surreal export` against the live server
into its own PVC, and Kasten snapshots that PVC. Each database export is read inside one
transaction, so the copy is consistent while clients keep writing — with no write pause.

## Pick the folder for your SurrealDB version

| SurrealDB | Folder | Kubernetes | Kasten | Keeper image | Status |
|---|---|---|---|---|---|
| 3.3.5 | [3.3/](3.3/) | 1.34.1 | 9.0.8 | `surrealdb/surrealdb:v3.3.5-dev` | Validated end to end (Steps 1–6), restore from export |

A folder is a **record of what was validated** on that version. It is not changed when work moves
to another version. To add a version (SurrealDB 4.0 is the next one planned), copy the nearest
folder, adapt it, and re-run Steps 2–5 of [AGENTS.md](../AGENTS.md).

### What changes between SurrealDB 3 and 4

| | 3.3 | 4.0 |
|---|---|---|
| `surreal export` / `import` | Yes, one transaction per database | Same |
| `-dev` image with a shell | Yes | Yes |
| On-disk storage engines | RocksDB, SurrealKV, TiKV | **SurrealKV only** |
| Upgrade in place from the previous major | No — a migration | No — a migration |

The 3.3 folder already uses SurrealKV, so a 4.0 folder should differ mainly by image tag. That
is an expectation, not a validation.

## Shared across versions

| File | Purpose |
|---|---|
| [surrealdb.pptx](surrealdb.pptx) | Concept deck, built from [ppt-tools/deck.py](ppt-tools/deck.py) |
