---
title: PostgreSQL container readiness must exclude the temporary init postmaster
date: 2026-07-21
status: active
tags: [gotcha, postgres, docker, ci, readiness, recovery]
related_files: [.github/workflows/ci.yml, compose.sync.yml, server/sync/compose.prod.yml, src/lib/sync/ci-recovery-workflow-contract.test.ts, src/lib/sync/deployment.test.ts]
---

## Durable fact

The official PostgreSQL container entrypoint starts a temporary socket-only
postmaster while initializing an empty data directory, stops it, and only then
executes the final PostgreSQL server as PID 1. A socket-only `pg_isready` can
therefore report success for the temporary server and release a destructive
recovery workflow into the intentional stop/start gap.

## Rule

- For fresh-volume container readiness, require `/proc/1/comm` to be exactly
  `postgres` and require `pg_isready` over `127.0.0.1` before any classification,
  migration, restore, or dependent-service startup.
- Use the same final-PID-and-TCP health contract in CI service containers and
  development/production Compose files; do not let environments disagree.
- Keep a workflow contract test that pins the PID 1 check and TCP probe before
  target binding/classification. The live destructive CI recovery remains the
  authoritative runtime proof.
