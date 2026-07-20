---
title: PostgreSQL template0 restores inherit pg_database_owner for public
date: 2026-07-20
status: active
tags: [gotcha, postgres, restore, ownership, least-privilege]
related_files: [server/sync/provision-runtime-role.sh, server/sync/database-role-tests.sh, server/sync/manage-prod.sh, .github/workflows/ci.yml]
---

## Durable fact

On PostgreSQL 16, a database created from `template0` with
`OWNER address_atlas` still starts with the `public` schema owned by the
predefined `pg_database_owner` role. `pg_restore --no-owner` preserves that
owner. Treating only direct `address_atlas` ownership as valid therefore makes
a clean, production-shaped restore fail even though no hostile drift occurred.

## Rule

- In `restore` and `drill` mode, accept exactly `pg_database_owner` or
  `address_atlas` as the pre-convergence `public` owner, then normalize it to
  `address_atlas` inside the same transaction as privilege convergence.
- Reject every other owner. Do not silently normalize it.
- Keep `steady` mode fail-closed; normal runtime provisioning must not repair
  ownership drift automatically.
- Test with a real PostgreSQL 16 database created from `template0`. Prove both
  rollback after a later convergence failure and preservation of role-global
  attributes and SCRAM verifiers.
