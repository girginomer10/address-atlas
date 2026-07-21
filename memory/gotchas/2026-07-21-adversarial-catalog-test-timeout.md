---
title: Full catalog adversarial matrices need an explicit finite test budget
date: 2026-07-21
status: active
tags: [gotcha, postgres, vitest, ci, readiness]
related_files: [src/lib/sync/postgres-schema-readiness.integration.test.ts]
---

## Symptom

The exact runtime-role and ACL readiness matrix passed locally but timed out at
Vitest's 5-second unit-test default on a loaded GitHub runner. The test performs
dozens of serial role/ACL mutations and full PostgreSQL catalog scans; CI reached
5.007 seconds while the rest of the 567-test suite kept passing.

## Root cause

The matrix inherited a unit-test latency budget that did not describe its work.
This was runner-load sensitivity, not an unbounded production query or a failed
assertion: the focused real-PostgreSQL file completed all seven tests in 2.19
seconds locally, and the complete integration suite remained green.

## Fix and invariant

Give only this deliberate catalog matrix a finite 20-second ceiling. Keep the
global Vitest default strict, keep every production statement/lock timeout
unchanged, and do not paper over an individual SQL hang with a suite-wide
timeout. Any future expansion of the matrix must still fit this explicit bound.

## Verification

- Focused real-PostgreSQL readiness file: 7/7 in 2.19 seconds.
- Full real-PostgreSQL suite under parallel file load: 50 files, 567/567.
