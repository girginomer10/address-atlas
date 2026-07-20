---
title: Bootstrap surface gate must tolerate missing repairable constraints
date: 2026-07-20
status: active
tags: [bugfix, postgres, bootstrap, schema-contract, trigger]
related_files: [src/lib/sync/postgres-schema.ts, src/lib/sync/postgres-readiness.ts, src/lib/sync/postgres-schema-migration.integration.test.ts, src/lib/sync/vault-storage.integration.test.ts]
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

This incident predates the numbered-migration refactor. The current invariant is
stricter and simpler: immutable, checksummed migrations own every supported
schema transition, while readiness validates the exact resulting contract.
Never reintroduce a generic catalog-deparse/repair machine. Known historical
layouts need an explicit adoption migration; unknown drift remains fail-closed.

Any test (or admin script) that inserts `vault_snapshots` rows directly MUST
mirror the production counter charge on `sync_storage_usage`, or its deletes
will fail closed by design.

## Verification

- Run the split real-PostgreSQL suites, including
  `postgres-schema-migration.integration.test.ts`, readiness, passkey, session,
  and vault-storage integration tests, on both a fresh database and a second
  bootstrap over the existing migration ledger. Never trust the mocked suite
  alone; drift, trigger, privilege, and migration semantics only exist against
  a real PostgreSQL 16.
