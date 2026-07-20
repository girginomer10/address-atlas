---
title: PostgreSQL integration roles must prove password authentication
date: 2026-07-20
status: active
tags: [gotcha, postgres, integration-test, scram, ci]
related_files: [src/lib/sync/postgres-schema-readiness.integration.test.ts, .github/workflows/ci.yml]
---

## Durable fact

A role test that passes against a local cluster configured with `trust` may still
fail in production-like PostgreSQL with SCRAM. Creating a `LOGIN` role without a
password and clearing the connection URL password does not test authentication;
it only inherits the local host-based authentication shortcut.

## Rule

Integration tests that open a new PostgreSQL connection as a generated runtime,
admin, or owner role must create a random per-run password and put the same value
in the connection URL. Keep the password ephemeral and never log or persist it.
Use a password-authenticated PostgreSQL 16 service in CI even when a disposable
local `trust` cluster is also used for fast iteration.
