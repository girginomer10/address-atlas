---
title: Native-config receipts require an uncached deployment probe
date: 2026-07-21
status: active
tags: [gotcha, deployment, native-config, cache, recovery]
related_files: [.github/workflows/ci.yml, src/app/config/native/route.ts, server/sync/native-config-deploy-state.mjs]
---

## Durable fact

The ordinary `/config/native` response is deliberately cacheable with
`public, max-age=300`. A deployment or bootstrap-finalization receipt must
instead prove the current origin response, its config digest, and the exact
serving revision. `native-config-deploy-state.mjs verify-response` therefore
requires `Cache-Control: no-store` in addition to the ETag and build-revision
header. A matching body fingerprint alone is not sufficient provenance.

## Rule

- Request `/config/native?deployment_probe=<expected-revision>` (or the
  equivalent release probe) whenever persisting a deployment receipt.
- Verify the returned body fingerprint and response headers against the same
  expected revision before writing durable state or finalizing recovery.
- Keep a workflow-contract test that prevents recovery CI from falling back to
  the normal cacheable endpoint.
