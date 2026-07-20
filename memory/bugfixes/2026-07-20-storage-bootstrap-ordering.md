---
title: Bootstrap surface gate must tolerate missing repairable constraints
date: 2026-07-20
status: active
tags: [bugfix, postgres, bootstrap, schema-contract, trigger]
related_files: [src/lib/sync/postgres.ts, src/lib/sync/postgres.integration.test.ts]
---

## Symptom

The first real-Postgres CI run of the hardened schema code failed all 11
postgres integration tests. One test failed with "bootstrap surface contains
unsafe behavior" during a re-bootstrap that was expected to repair a dropped
check constraint; ten others failed in the shared `afterEach` with the delete
trigger raising "snapshot usage counter is missing or inconsistent".

## Root causes

1. `assertStorageBootstrapSurfaceSafe` ran before any DDL and required the
   exact contract constraint count on `sync_storage_usage`. A MISSING
   repairable check — exactly what `CORE_SCHEMA_REPAIR_SQL` exists to re-add
   (pkey, singleton, storage, and version checks are all re-addable) — was
   indistinguishable from hostile drift, so bootstrap failed closed before its
   own repair could run. The gate rejected schemas its own repair path was
   designed to fix; this was invisible until code ran against a live database.
2. A test inserted a `vault_snapshots` row with raw SQL, bypassing
   `saveVaultSnapshot`'s global byte-counter charge. The strict delete trigger
   fails closed when the decrement would push the counter below zero, so the
   cleanup cascade raised — and because `testUserIds` only clears after a
   successful delete, one poisoned cleanup made every later test in the file
   fail the same way (misleading blast radius).

## Fix and invariant

The pre-DDL surface gate's job is to reject only what bootstrap must never
touch: constraints outside the known-safe shapes (e.g. same-name-but-weaker
checks), any trigger on the storage table, or a stray index. Missing contract
constraints are tolerated — repair re-adds them and final readiness still
enforces the full contract. Keep this division of labor: gate = "nothing
unexpected", repair = "restore the expected", readiness = "everything exact".

Any test (or admin script) that inserts `vault_snapshots` rows directly MUST
mirror the production counter charge on `sync_storage_usage`, or its deletes
will fail closed by design.

## Verification

- Fresh-database run of `postgres.integration.test.ts` (11/11) plus a second
  bootstrap over the existing schema — the second run exercises the strict
  marker-present gate path that a fresh run skips. Never trust the mocked
  suite alone for this file; the drift/migration semantics only exist against
  a real PostgreSQL 16.
