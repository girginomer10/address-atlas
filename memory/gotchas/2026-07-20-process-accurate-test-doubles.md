---
title: Process test doubles must preserve platform and stdin semantics
date: 2026-07-20
status: active
tags: [gotcha, testing, macos, xprotect, bash]
related_files: [src/lib/sync/release-doctor.test.ts, server/sync/ops-script-tests.sh]
---

## Durable fact

On macOS, repeatedly creating and executing fresh `0755` command stubs can
trigger XProtect provenance scans. Synchronous child execution blocks the test
runner while this happens, so a framework timeout may fire only after the
process finally returns. Separately, a fake command that reads stdin when the
real command-mode invocation does not can hang forever under a TTY while
appearing healthy in non-interactive CI.

Bash 3.2 also treats expansion of an empty array under `set -u` differently
from current Bash. A helper that passes on Bash 5 can fail before invoking the
system under test.

## Rule

- Use one suite-scoped executable dispatcher and symlink command names to it;
  keep per-test command bodies non-executable and isolated.
- Make test doubles match the real command's stdin, argv, stdout/stderr, and
  exit behavior. Exercise critical helpers both with and without a TTY.
- Under the Bash 3.2 compatibility matrix, seed optional command arrays with
  the mandatory executable instead of expanding an empty array under
  `set -u`.
- Fix platform/process fidelity rather than raising timeouts.
