---
title: Production control-state fixtures must override privileged defaults
date: 2026-07-21
status: active
tags: [gotcha, ci, testing, deployment, emergency-stop, filesystem]
related_files: [src/lib/sync/deployment.test.ts, server/sync/service-control.sh]
---

## Symptom

Deployment tests passed on a development Mac but cascaded with status 66 on a
clean GitHub runner before reaching their rollout and rollback assertions. The
runner reported that the emergency-control parent was not a canonical
non-symlink directory.

## Root cause

The test environment did not override `ADDRESS_ATLAS_CONTROL_ROOT`, so stateful
fixtures inherited the production default `/var/lib/address-atlas/service-control`.
The Mac already had the parent directory, masking the leak; the clean runner did
not. The production diagnostic intentionally combines missing, noncanonical,
and symlink-parent failures, so the message did not imply that CI used a symlink.

## Fix and invariant

Every stateful deployment fixture must bind control state inside its own
realpath-resolved, mode-0700 temporary root. Assert the exact path and private
parent permissions in the harness. Never weaken the production canonical-path,
ownership, or permissions checks to accommodate a test environment, and never
let tests read or mutate the production default control root.

## Verification

- Focused deployment suite: 59/59.
- Independent review confirmed that the fixture-only override preserves the
  production emergency-stop boundary.
