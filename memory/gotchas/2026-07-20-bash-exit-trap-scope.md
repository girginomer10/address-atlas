---
title: EXIT cleanup state must survive Bash function unwinding
date: 2026-07-20
status: active
tags: [gotcha, bash, operations, cleanup, signals]
related_files: [server/sync/postgres-backup.sh, server/sync/ops-script-tests.sh]
---

## Durable fact

An `EXIT` trap installed inside a function can run after that function's local
scope has unwound. Bash 3.2 may leave a dynamically scoped local visible on a
path where Bash 5 instead raises an unbound-variable error under `set -u`. The
result is worse than a cosmetic exit-code difference: staging data, operation
locks, or restore recovery state may not be cleaned or preserved as intended.

Wrapping a signal-owning operation in an extra subshell is not a safe scope
workaround. A signal sent to the original script PID can terminate the waiting
outer shell while leaving the subshell and its process-group descendants
orphaned.

## Rule

- Initialize mutable state consumed by a top-level `EXIT` cleanup as a uniquely
  operation-prefixed script global before installing the trap.
- Keep process-group and signal ownership in the original script process; do
  not add a subshell boundary merely to extend cleanup-state lifetime.
- Exercise the complete operations suite under macOS Bash 3.2 and a current
  Bash 5 runtime. Cancellation tests must prove exit 130/143 behavior,
  TERM-to-KILL escalation, lock preservation, and the absence of orphan
  descendants.
