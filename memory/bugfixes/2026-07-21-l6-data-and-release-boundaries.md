---
title: L6 data boundaries must bind identity, snapshot, durability, and release evidence
date: 2026-07-21
status: active
tags: [bugfix, macos, sync, postgres, release, solana, xrpl, evm, passkeys, sqlite, exchange, kraken, accessibility]
related_files: [native/AddressAtlasMac/Sources/AddressAtlasCore/Sync/PendingVaultUpload.swift, native/AddressAtlasMac/Sources/AddressAtlasCore/Storage/EncryptedSQLiteVaultStore.swift, native/AddressAtlasMac/Sources/AddressAtlasCore/Scanners/ExchangeAmount.swift, native/AddressAtlasMac/Sources/AddressAtlasCore/Scanners/KrakenNonce.swift, native/AddressAtlasMac/Sources/AddressAtlasCore/Scanners/NativeScannerSolana.swift, native/AddressAtlasMac/Sources/AddressAtlasCore/Scanners/NativeScannerXRP.swift, native/AddressAtlasMac/Sources/AddressAtlasCore/Scanners/NativeScannerBitcoinEVM.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/AppStateTermination.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/AppStateAccountLifecycle.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/AppStateEndpointConfiguration.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/AppStateVaultSync.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/ExchangeSyncViews.swift, src/lib/sync/postgres-readiness.ts, src/lib/sync/postgres-schema.ts, src/lib/sync/postgres-search-path.ts, src/lib/sync/restore-readiness.ts, src/lib/sync/stored-vault-row.ts, src/lib/sync/rate-limit.ts, src/lib/sync/postgres-migrations/index.ts, src/lib/sync/postgres-migrations/004-vault-envelope-storage-bound.ts, src/app/auth/passkey/body-concurrency.ts, src/app/vault/latest/route.ts, server/sync/Dockerfile, server/sync/manage-prod.sh, server/sync/postgres-backup.sh, .github/workflows/release.yml]
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
- A downloaded remote vault needs an encrypted full-document checkpoint before
  destructive adoption. The at-rest checkpoint includes credentials and the
  historical sync state, but restoration must atomically apply only its
  user-controlled vault content onto the entire current `SyncState`. Preserve
  the current account, server, bearer session, remote version, checksums, and
  outcome markers so restored content can be uploaded over the snapshot that
  triggered rollback; consume the checkpoint only in that same commit.
  Disconnect and account deletion must durably discard it before clearing
  account identity, or a later restore could resurrect prior-account secrets.
- Treat the local SQLite file and its app-owned leaf directory as hostile
  filesystem inputs. Reject a symlinked leaf directory, symlinked database,
  hard-linked database, wrong owners, and post-open path/inode mismatches; use
  no-follow and close-on-exec opens, owner-only modes, SQLite length limits,
  bounded BLOB projections, and encoded-envelope limits before allocating
  attacker-controlled data. Canonical macOS system ancestors such as `/var`
  may legitimately traverse a platform symlink.
- Exchange quantities are wire-exact decimal values, not binary floating-point
  totals. Parse and add canonical base-10 values with explicit significant-digit
  and wire-size bounds, persist and export the exact form, and derive `Double`
  only as a compatibility view for valuation. If duplicate provider aliases
  disagree or one alias is malformed, quarantine the normalized symbol rather
  than silently returning a partial total.
- A monotonic exchange nonce contract is cross-process. Test it with separate
  OS processes sharing an isolated real Keychain namespace and state file,
  including a process that exits immediately after persistence. Nested xctest
  workers cannot reliably load Thread Sanitizer early enough, so only this
  process harness is skipped under TSan; the normal suite must always run it.
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
- Keep the next migration immutable and prepared one release ahead. The active
  image may accept only its exact current head and the checksum-verified prepared
  next head; modified, unknown, or further-future heads fail closed. This creates
  an auditable N/N-1 rolling window without advancing the live schema early.
  Any prepared expand DDL must inspect the catalog and skip its `ALTER TABLE`
  when the current release already converged the attribute; otherwise activation
  can reacquire an avoidable access-exclusive lock despite making no change.
- Add a large-table constraint as `NOT VALID` in the expand migration and
  validate it in a later migration. `ADD CONSTRAINT` retains its
  access-exclusive lock until transaction commit, so validating in the same
  migration defeats the weaker-lock benefit even when `VALIDATE CONSTRAINT`
  itself uses a less restrictive lock.
- A rollback image capability is an exact migration-chain claim, not merely a
  numeric maximum. Read the current durable head from verified, signed
  pre-deploy backup metadata, require the captured image's maximum to cover
  `max(current head, active head)`, and match that head's cumulative chain
  digest label. Missing both labels is accepted only for a legacy image already
  serving an unchanged active-head database; a partial label set or any schema
  advance fails before build or migration. A transaction-consistent `pg_dump`
  plus the shared schema advisory lock permits this safety backup while the
  verified web tier remains available; destructive restore still quiesces it.
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
- PostgreSQL physical safety checks precede logical parsing. Inspect compression
  and raw datum size before casts, rendering, JSONB access, or client projection;
  a pre-cutover owner scan must reject compressed or oversized legacy envelopes
  without detoasting them. Apply `SET STORAGE EXTERNAL` only when storage policy
  actually differs so routine convergence does not reacquire an unnecessary
  access-exclusive table lock.
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

- Web unit and contract suite: 447 passed, 50 environment or live tests
  skipped; operations passed 58/58. Focused PostgreSQL 16.14 migration/vault
  and readiness suites passed 27/27 and 6/6.
- Native suite: 385 tests, 2 opt-in live tests skipped; strict concurrency and
  warnings-as-errors passed. Thread Sanitizer passed the same suite with one
  additional, explicitly documented nested-process harness skip and no race
  report.
- Operations: 58 passed. Notary credential/timeout and build-version harnesses
  passed. The universal x86_64/arm64 app bundle passed plist, icon, hardened
  runtime, and signature verification.

## External boundary

Code-level readiness does not prove public release readiness. DNS/deployment,
GitHub governance settings, Apple Developer ID/notarization credentials, pager
delivery, offsite recovery custody, and a timed cross-host RTO drill require
owner-controlled systems and separate evidence.
