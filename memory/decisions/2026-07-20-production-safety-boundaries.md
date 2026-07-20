---
title: Production boundaries fail closed before expensive or irreversible work
date: 2026-07-20
status: active
tags: [decision, security, operations, release, availability]
related_files: [src/lib/sync/rate-limit.ts, src/app/vault/latest/route.ts, src/app/healthz/route.ts, server/sync/manage-prod.sh, server/sync/postgres-backup.sh, scripts/release-doctor.sh, .github/workflows/release.yml, native/AddressAtlasMac/Sources/AddressAtlasMac/AtlasDesignSystem.swift]
---

## Context

Address Atlas combines an internet-facing opaque-vault service, a local encrypted
Mac client, PostgreSQL state, and destructive production recovery/release paths.
Local correctness is insufficient if untrusted requests can consume database or
memory capacity first, or if an interrupted operator action can resume against a
different source revision, database, or release artifact.

## Decision

Security and continuity checks run at the earliest trustworthy boundary:

- Public routes perform global and client admission before database access, and
  large uploads reserve bounded global/client/account concurrency before reading
  the body. After authentication, the service-wide received-byte charge commits
  independently before the account quota transaction, so an account rejection
  cannot refund traffic the service already accepted.
- Readiness caches and singleflights the complete configuration, native-contract,
  schema, and deep-database pipeline; liveness remains database-free.
- Production mutations share a host lock, record exact immutable source and
  toolchain identities, and use durable phase receipts so retries can only resume
  the same intended operation. Recovery finalizes state before releasing its lock.
- Release automation verifies protected-environment and repository governance,
  signed/notarized universal artifacts, checksums, attestations, and create-once
  release semantics before publication.
- Custom SwiftUI controls must honor `isEnabled` visually as well as through the
  accessibility tree; disabled security actions cannot look actionable.

## Consequences

- Unknown schema drift, ambiguous recovery state, artifact replacement, and
  missing external governance stop the operation instead of being auto-repaired.
- Live pager delivery, offsite recovery-key availability, cross-host timed RTO,
  signing/notarization credentials, and GitHub settings remain deployment evidence;
  passing repository tests does not substitute for those operator proofs.
- Future endpoints that accept large bodies must preserve the same ordering:
  cheap global/client admission, authentication, account-aware concurrency,
  bounded body read, independent durable global charge, account quota enforcement,
  then content interpretation and mutation.
