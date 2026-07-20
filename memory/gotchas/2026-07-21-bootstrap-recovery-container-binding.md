---
title: Bootstrap recovery must bind source and target containers by phase
date: 2026-07-21
status: active
tags: [gotcha, backup, bootstrap, docker, ci]
related_files: [.github/workflows/ci.yml, src/lib/sync/ci-recovery-workflow-contract.test.ts, server/sync/postgres-backup.sh]
---

## Durable fact

`postgres-backup.sh inspect` does more than parse signed metadata: it also runs
the normal encrypted-backup verification path, including `pg_restore --list`
and database-context checks in a live PostgreSQL container. A destructive
fresh-volume recovery has two different authoritative containers over time.
Relying on Compose-label discovery fails for GitHub service containers and
ad-hoc recovery targets, even when both containers are otherwise healthy.

## Rule

- Explicitly bind `ADDRESS_ATLAS_POSTGRES_CONTAINER` to the live source before
  inspecting the artifact and before deleting the original service/volume.
- After the new empty target is running, explicitly rebind the same variable to
  that target before classification, bootstrap restore, and final validation.
- Keep a workflow-contract test that proves the ordering: source binding,
  artifact inspection, source removal, target binding, then target
  classification. Do not depend on implicit Compose labels across this phase
  transition.
