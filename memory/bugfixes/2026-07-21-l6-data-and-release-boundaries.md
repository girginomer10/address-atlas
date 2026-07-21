---
title: L6 data boundaries must bind identity, snapshot, durability, and release evidence
date: 2026-07-21
status: active
tags: [bugfix, macos, sync, postgres, release, solana, xrpl, evm, passkeys]
related_files: [native/AddressAtlasMac/Sources/AddressAtlasCore/Sync/PendingVaultUpload.swift, native/AddressAtlasMac/Sources/AddressAtlasCore/Storage/EncryptedSQLiteVaultStore.swift, native/AddressAtlasMac/Sources/AddressAtlasCore/Scanners/NativeScannerSolana.swift, native/AddressAtlasMac/Sources/AddressAtlasCore/Scanners/NativeScannerXRP.swift, native/AddressAtlasMac/Sources/AddressAtlasCore/Scanners/NativeScannerBitcoinEVM.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/AppStateTermination.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/AppStateEndpointConfiguration.swift, src/lib/sync/postgres-readiness.ts, src/lib/sync/postgres-schema.ts, src/lib/sync/postgres-search-path.ts, src/lib/sync/restore-readiness.ts, src/lib/sync/stored-vault-row.ts, src/lib/sync/rate-limit.ts, src/app/auth/passkey/body-concurrency.ts, src/app/vault/latest/route.ts, .github/workflows/release.yml]
---

## Durable invariants

- Treat an outbound vault upload as a durable state machine. Encrypt and persist
  the exact predecessor, candidate, envelope, checksum, account, endpoint, and
  version before the first PUT. Block competing primary-document writers while
  that intent exists; after an ambiguous response, replay or recognize only the
  exact operation. Never prune local history before remote commit is proven.
- Remote configuration trust is a transaction: validate a candidate and publish
  its high-water version atomically only after the authenticated account/session
  boundary succeeds. Cancellation or failed authentication must not advance
  durable trust state.
- Provider data is acceptable only when it is bound to both the requested
  identity and one coherent snapshot. Solana token accounts must echo the exact
  owner, token program, and parsed type; aggregate canonical raw `UInt64` values
  once per mint with one decimals value. `minContextSlot` is only a floor, so
  SOL, Token, and Token-2022 reads must converge on the same returned slot with
  bounded retries or fail closed. XRP native and issued balances must share one
  validated ledger identity across every page. EVM native and ERC-20 balances,
  including fallback calls, must share one canonical block tag. Bind Bitcoin,
  TRON, and Cosmos responses to the requested address/delegator and reject
  conflicting duplicate records rather than double counting them.
- A shared asynchronous fetch needs waiter ownership, not shared cancellation.
  Give each caller an independently cancellable lease, keep the request
  registered while any lease survives, and cancel the underlying task only
  when the final owner leaves or the authority changes.
- Application termination is a durability transaction. Freeze new mutations,
  wait for the outcome of any active save, flush lifecycle-owned UI drafts and
  any in-memory post-sync persistence candidate, and cancel termination on any
  validation or save failure. A durable upload journal may survive a quit; an
  in-memory-only pending candidate may not.
- PostgreSQL migration history alone is not permission to mutate. Under the
  advisory lock, validate the exact predecessor schema surface inside the same
  transaction before each pending migration, validate the resulting surface
  before commit, and validate again before reconciliation. Drift is diagnostic;
  it must remain byte-for-byte and catalog-for-catalog untouched on rejection.
- A schema migration must remain compatible with both the new image and the
  immediately previous image throughout deploy and rollback. First ship code
  that tolerates both schema shapes, then migrate in a later release; do not
  combine a new exact migration head or constraint set with code that makes the
  previous image reject the database.
- Integration fixtures must respect that exactness too. If a role-boundary test
  creates adversarial objects in `public`, prove their grants are revoked and
  bootstrap rejects the expanded surface, then remove those fixture objects
  before testing a no-op bootstrap. Production-mode migrations against allowed
  `atlas_drill_*` or `atlas_restore_*` databases must set the explicit
  restore-migration flag; never weaken the fixed production database rule.
- Production pools must configure exactly `search_path=public` and leave
  `pg_catalog` implicit. PostgreSQL then resolves built-ins through
  `pg_catalog` first while retaining `public` as the creation schema. Never
  change this to `public,pg_catalog`: that makes owner-writable public
  functions, types, and operators shadow built-ins during restore migration.
  The restore probe must validate exact current/session identity, configured,
  explicit, and effective paths with catalog-qualified functions/operators, and
  a real PostgreSQL integration test must exercise both safe and unsafe order.
- Public auth capacity starts before reading request bytes. Bound global and
  per-client concurrent body readers, impose a body deadline, release the permit
  before WebAuthn/database work, and never expose raw framework/server errors to
  the native return bridge. A lost verification response is an unknown outcome,
  not a proven failure.
- Registration edge capacity and durable account admission are separate. Use
  cheap pre-body controls to protect request processing, but consume the durable
  registration budget only inside the successful WebAuthn/account transaction.
- Authenticated vault ingress must check exhausted durable budgets before body
  receipt, then lock user, account usage, and global usage in one deterministic
  order. Every admitted body charges its actual received bytes globally; an
  over-budget account counter saturates and commits before rejection, while a
  missing account must not consume shared capacity. Never trust Content-Length
  as the received-byte count.
- Revalidate every stored encrypted snapshot on read and during restore
  readiness: shape, canonical byte size, inner ciphertext checksum, and outer
  version-bound checksum. Classify and guard oversized PostgreSQL values before
  projecting them into the application, distinguish corruption from absence,
  scan restores through a bounded server-side cursor, and expose only
  allow-listed operational error categories.
- A successful vault download owns its concurrency permit through response
  drain or cancellation, not merely until the route returns. Charge the exact
  encoded response bytes atomically against account, client, and global egress
  windows before streaming; bind request aborts to the lease transfer and keep
  a finite reverse-proxy write deadline so slow readers cannot pin capacity.
- Release evidence is an identity set, not a green context label. Bind the exact
  source SHA, workflow run ID, attempt, required job names, check-run IDs/URLs,
  and producing GitHub App; re-fetch and compare them immediately before
  publication. Strict Swift concurrency, signed-bundle metadata, backup config
  freshness, and finite notarization timeouts are release gates.

## Verification baseline

- Production-pinned PostgreSQL 16.14 plus the full web suite: 478 tests passed
  across 46 files.
- Native suite: 358 tests, 2 opt-in live tests skipped; strict concurrency and
  full Thread Sanitizer passed with no race finding.
- Operations: 58 passed. Notary credential/timeout and build-version harnesses
  passed. The universal x86_64/arm64 app bundle passed plist, icon, hardened
  runtime, and signature verification.

## External boundary

Code-level readiness does not prove public release readiness. DNS/deployment,
GitHub governance settings, Apple Developer ID/notarization credentials, pager
delivery, offsite recovery custody, and a timed cross-host RTO drill require
owner-controlled systems and separate evidence.
