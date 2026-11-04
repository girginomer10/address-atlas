---
title: CI checks must remain strict while fixtures and dependency pins stay portable
date: 2026-11-04
status: active
tags: [bugfix, ci, dependencies, testing, memory]
related_files: [package.json, package-lock.json, native/AddressAtlasMac/Tests/AddressAtlasCoreTests/ExporterTests.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/AppStateExchangeConnections.swift, src/lib/repo-memory.test.ts, src/lib/sync/deployment.test.ts, README.md]
---

## Root causes

- A decimal-export test passed a large integer literal directly to a Double parameter. The compiler rounded it with a warning, so the normal tests passed but CI warnings-as-errors failed.
- Coinbase field-help copy contained a complete PEM opening delimiter and triggered the repository secret-artifact scanner despite containing no key material.
- The memory integration test assumed every clone directory was named address-atlas, although the cache identity deliberately incorporates the resolved checkout path and sanitized directory name.
- A full shell deployment/preflight scenario inherited the 5-second unit-test timeout and exceeded it under concurrent build/test load, despite completing its workflow. Its sibling lifecycle scenarios already used 15-second budgets.
- Exact dependency pins and the lockfile retained newly reported vulnerabilities until refreshed.

## Fix and invariants

- Construct the large test value as UInt64, then explicitly convert it to Double. Preserve the same expected decimal output and the strict compiler gate.
- Describe the PEM BEGIN and END lines in prose; do not put complete credential delimiters in UI help or weaken the secret scanner for documentation.
- Compare search.repo_id with doctor.repo_id and validate the identifier shape. Never hard-code a checkout directory name in this integration assertion; separate clones must still have separate cache identities.
- Give the full pre-deploy-order scenario the same finite 15-second budget as its sibling lifecycle tests; retain every order/status assertion and keep unit-test defaults unchanged.
- Audit the complete resolved graph after dependency changes, including the pinned Vite override and optional platform binaries. A clean npm ci and both full and production-only audits must pass.
- Keep the public README walkthrough usable with Xcode and a public wallet address, without requiring Node.js or an exchange account. Source-build instructions do not imply public signed distribution.

## Verification

- Strict Swift tests passed with the decimal-export expectation unchanged.
- Repository secret-artifact scan and all 22 scanner canaries passed.
- All 8 memory-tool tests passed in a separate clone named checkout.
- Clean npm ci, full npm audit, production-only audit, TypeScript checking, and Next.js production build passed. Both audits reported zero vulnerabilities on 2026-11-04; re-check current advisories before future releases.
