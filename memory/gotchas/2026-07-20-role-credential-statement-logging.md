---
title: Role credentials must never enter SQL statement text
date: 2026-07-20
status: active
tags: [gotcha, postgres, credentials, logging, psql]
related_files: [server/sync/bootstrap-database-roles.sh, server/sync/provision-runtime-role.sh, server/sync/database-role-tests.sh, server/sync/ops-script-tests.sh]
---

## Durable fact

Passing a password through a psql variable is not sufficient secrecy when that
variable is expanded into role DDL. The plaintext can enter client-submitted
statement text and then appear in `log_statement`, debug parse/rewritten logs,
`pg_stat_statements`, pgAudit, PL/pgSQL error context, or shell `-x` output.
Suppressing only the final command's stderr does not close these paths.

## Rule

- Disable shell tracing before reading any credential-bearing environment
  variable.
- Transport credentials as `COPY FROM STDIN` data into transaction-scoped temp
  storage; never interpolate them into client-submitted SQL text.
- Use fixed role identifiers and server-side dynamic DDL with `%L`, while
  disabling nested statement statistics/audit collectors for the credential
  transaction and sanitizing every exception path.
- Emit only fixed stage markers to operators. Keep raw psql stdout and stderr
  behind the secret boundary.
- Pressure-test a real PostgreSQL 16 server with statement/debug logging and
  `pg_stat_statements` enabled, then scan both outputs for every known secret,
  its encoded form, and unknown generated bridge-role password patterns.
