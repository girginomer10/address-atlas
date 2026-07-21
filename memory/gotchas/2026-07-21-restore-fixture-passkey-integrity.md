---
title: Recovery fixtures must satisfy production passkey integrity
date: 2026-07-21
status: active
tags: [gotcha, postgres, passkeys, webauthn, cose, backup, restore, ci]
related_files: [.github/workflows/ci.yml, src/lib/sync/ci-recovery-workflow-contract.test.ts, src/lib/sync/restore-readiness.ts, src/lib/sync/stored-passkey-credential.ts]
---

## Symptom

The encrypted backup was created and verified, but both the drill and atomic
restore stopped at the migration/readiness hook after stored passkey validation
became strict. The fixture contained base64url text for `ci-public-key`, not a
COSE public key that a WebAuthn verifier could import.

## Rule

- Recovery fixtures are production-shaped data, not arbitrary relational rows.
  Every restored account must retain at least one cryptographically importable
  credential allowed by the current passkey policy.
- Never weaken restore readiness to accommodate a placeholder fixture. Seed a
  valid ES256/P-256 or RS256/RSA credential instead.
- Keep the workflow contract test coupled to the production credential-ID and
  public-key validators so malformed recovery data fails in the fast unit suite
  before the destructive GitHub Actions drill.

## Verification

- Recovery workflow contract: 6/6.
- Full local Vitest suite: 44 files / 517 tests passed; 6 environment-gated
  files / 51 tests skipped.
- TypeScript typecheck and diff whitespace checks passed.
- The replacement GitHub Actions backup/drill/restore run remains the
  authoritative end-to-end proof.
