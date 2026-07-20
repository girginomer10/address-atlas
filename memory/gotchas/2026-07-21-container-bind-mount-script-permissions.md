---
title: Restore helper bind mounts must survive container privilege drop
date: 2026-07-21
status: active
tags: [gotcha, docker, restore, permissions, postgres]
related_files: [server/sync/provision-restored-database.sh, src/lib/sync/restore-provision-hook.test.ts, .github/workflows/ci.yml]
---

## Durable fact

The reviewed PostgreSQL image entrypoint drops from root to its unprivileged
`postgres` user before executing a supplied command. A host-owned restore helper
staged as mode `0500` therefore becomes unreadable when bind-mounted into that
container, even when the Docker daemon could traverse the private host staging
directory. Invoking it through `/bin/sh` does not bypass the file read check.

## Rule

- Keep the host staging directory operator-owned at mode `0700` so other host
  users cannot traverse it.
- Stage non-secret helper code at mode `0555`, bind-mount the exact snapshot
  read-only, and retain the read-only root filesystem, dropped capabilities,
  and `no-new-privileges` container boundaries.
- Unit tests must capture both the staged file and parent-directory modes at
  the Docker invocation boundary. The production-shaped CI restore remains the
  final proof that the pinned image can execute the snapshot after its
  entrypoint privilege drop.
