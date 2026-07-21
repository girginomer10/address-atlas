---
title: L6 data boundaries must bind identity, snapshot, durability, and release evidence
date: 2026-07-21
status: active
tags: [bugfix, macos, sync, postgres, release, solana, xrpl, evm, passkeys, webauthn, cose, sqlite, exchange, kraken, cosmos, tron, accessibility]
related_files: [native/AddressAtlasMac/Sources/AddressAtlasCore/Sync/PendingVaultUpload.swift, native/AddressAtlasMac/Sources/AddressAtlasCore/Sync/EndpointConfigTrustStore.swift, native/AddressAtlasMac/Sources/AddressAtlasCore/Storage/EncryptedSQLiteVaultStore.swift, native/AddressAtlasMac/Sources/AddressAtlasCore/Storage/DamagedVaultRecovery.swift, native/AddressAtlasMac/Sources/AddressAtlasCore/Storage/VaultFileAccessLock.swift, native/AddressAtlasMac/Sources/AddressAtlasCore/Scanners/ChainNetworkIdentityProofCache.swift, native/AddressAtlasMac/Sources/AddressAtlasCore/Scanners/Exporters.swift, native/AddressAtlasMac/Sources/AddressAtlasCore/PrivacySafeDiagnostics.swift, native/AddressAtlasMac/Sources/AddressAtlasCore/Scanners/ExchangeAmount.swift, native/AddressAtlasMac/Sources/AddressAtlasCore/Scanners/KrakenNonce.swift, native/AddressAtlasMac/Sources/AddressAtlasCore/Scanners/NativeScannerSolana.swift, native/AddressAtlasMac/Sources/AddressAtlasCore/Scanners/NativeScannerXRP.swift, native/AddressAtlasMac/Sources/AddressAtlasCore/Scanners/NativeScannerBitcoinEVM.swift, native/AddressAtlasMac/Sources/AddressAtlasCore/Scanners/NativeScannerCosmos.swift, native/AddressAtlasMac/Sources/AddressAtlasCore/Scanners/NativeScannerTron.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/AppStateTermination.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/AppStateAccountLifecycle.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/AppStateEndpointConfiguration.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/AppStateVaultSync.swift, native/AddressAtlasMac/Sources/AddressAtlasMac/ExchangeSyncViews.swift, src/lib/sync/postgres-readiness.ts, src/lib/sync/postgres-schema.ts, src/lib/sync/postgres-search-path.ts, src/lib/sync/restore-readiness.ts, src/lib/sync/stored-vault-row.ts, src/lib/sync/stored-passkey-credential.ts, src/lib/sync/passkey-credential-integrity.ts, src/lib/sync/storage-ledger-integrity.ts, src/lib/sync/rate-limit.ts, src/lib/sync/auth-database-concurrency.ts, src/lib/sync/authentication-lock-order.ts, src/lib/sync/postgres-migrations/index.ts, src/lib/sync/postgres-migrations/004-vault-envelope-storage-bound.ts, src/lib/sync/postgres-migrations/005-passkey-storage-policy.ts, src/app/auth/passkey/body-concurrency.ts, src/app/auth/passkey/verification-concurrency.ts, src/app/auth/native/NativePasskeyBridge.tsx, src/app/vault/latest/route.ts, scripts/check-secret-artifacts.py, server/sync/Dockerfile, server/sync/manage-prod.sh, server/sync/service-control.sh, server/sync/postgres-backup.sh, .github/workflows/release.yml]
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
- Production connection URLs may be plaintext only when they contain no TLS
  query parameters, as in the private Compose network. Once any certificate,
  key, root, or negotiation parameter is present, require an explicit
  `sslmode=verify-full`; reject partial or downgrade-prone TLS combinations.
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
- A stored passkey is executable cryptographic state, not trusted text. Guard
  compressed and oversized PostgreSQL values before projection, accept only the
  application's explicit ES256/P-256 and RS256/RSA 2048-4096 policy, require the
  exact COSE field set and cryptographic key import, and reject every restored
  account that has no valid credential. Registration options, attestation
  verification, authentication, reads, and restore readiness must share that
  same frozen policy.
- Bound WebAuthn verification independently from request-body admission. Reserve
  database-pool capacity for non-auth work, cap global, client, and credential
  verification concurrency, and return a privacy-safe retryable overload result
  without letting credential IDs allocate unbounded state.
- Expensive storage-ledger reconciliation is a periodic integrity audit, not a
  synchronous health probe. Compare ledger and snapshot totals in one bounded
  repeatable-read snapshot; on drift, persist a sticky reconcile marker that
  blocks future vault writes while reads and authentication remain available.
  Do not hold the singleton ledger row across the aggregate scan.
- Endpoint configuration has separate visible and durable outcomes. A rename
  followed by an uncertain directory durability barrier may be usable for
  read-only display, but must block passkey, sync, recovery, and provider traffic
  until the exact record is re-fsynced. After relaunch, a remembered policy
  high-water value is not a fallback policy document; unavailable refreshes may
  reuse only an exact-authority policy accepted in the current process.
- Account detach is one lifecycle transaction: complete remote revocation first
  unless the user explicitly chooses local-only detach, then atomically persist
  identity cleanup and rollback-checkpoint removal. Pending upload recovery must
  refresh and validate endpoint trust and minimum-client policy before any GET
  or PUT.
- Paged provider records require snapshot and duplicate identity. Cosmos parts
  must echo one bound height through an accepted header, and Cosmos rewards or
  TRON contracts that repeat with conflicting values are quarantined instead of
  partially counted. Notarized distribution must prove both arm64 and x86_64;
  architecture order is irrelevant.
- A native-auth return page must be inert before hydration. Use an explicit
  button instead of implicit form submission, preserve callback/state in the
  URL, and expose bounded actionable status through semantic busy/live regions.
- Support output is an explicit privacy boundary. Diagnostics may contain only
  closed enum codes, coarse buckets, and bounded state flags; never preserve raw
  errors, labels, addresses, URLs, provider payloads, or credentials. Default
  CSV/JSON sharing must use one redacted DTO that excludes identifiers, exact
  values, history, settings, and sync authority. Full identifying exports need
  a separate, explicit disclosure and must never be described as anonymous.
- Damaged SQLite recovery is an inode-replacing maintenance transaction. Every
  normal vault store retains a shared process lease; quarantine/replacement
  requires a nonblocking exclusive lease, a byte-verified crash-durable copy,
  identity rechecks, full file and parent-directory barriers, and release of the
  exclusive lease before reopening the published clean store. Package metadata
  should also prohibit multiple app instances, but the file lease remains the
  authoritative cross-process safety boundary.
- A same-key asynchronous cache needs producer identity as well as waiter
  identity. Removing a last-waiter entry and starting a new generation must not
  let the canceled old producer publish into the replacement. Likewise, a vault
  download must revalidate the bearer at the final adoption boundary; if it
  expired during transfer/decryption, preserve local content and require fresh
  authentication before creating rollback or pending state.
- All public authentication work shares one database-capacity budget reserved
  below the pool ceiling. Validate token/shape/HMAC before acquiring that
  budget, and retain client/session/code-specific limits inside it. Transactions
  that touch account-owned rows must use one global parent-before-child lock
  order (`users` before credentials or grants), matching account deletion's
  cascade order; unlocked owner discovery must be revalidated after both locks.
- Logical guarded reads and physical PostgreSQL storage policy are one contract.
  If compressed values are rejected before detoast, convergence and the prepared
  migration must set those bounded credential columns to `STORAGE EXTERNAL`,
  readiness must assert it, and existing compressed rows must block cutover.
  Keep metadata-only expand migrations bounded; do not hide an unbounded
  `VALIDATE CONSTRAINT` scan inside a normal deploy transaction.
- Secret scanning cannot treat NUL as proof that a tracked file is harmless.
  Scan bounded mixed/binary bytes through a one-to-one ASCII-preserving view so
  credential signatures remain detectable, while retaining filename, size,
  symlink, allowlist-digest, and aggregate limits.
- An emergency stop is terminal only if it serializes with every legal service
  mutation. Publish and fsync a private durable stop fence, stop immediately,
  acquire a short cutover lock shared by every production `start`, `up`,
  `create`, and `run`, stop again, then verify no fixed-project container is
  running before success. Keep the fence until an exact confirmed clear under
  the normal operation lock. Never auto-delete an unbound stale cutover lock;
  fail closed and require explicit PID/start/Docker-state recovery.
- Release evidence is an identity set, not a green context label. Bind the exact
  source SHA, workflow run ID, attempt, required job names, check-run IDs/URLs,
  and producing GitHub App; re-fetch and compare them immediately before
  publication. Strict Swift concurrency, signed-bundle metadata, backup config
  freshness, and finite notarization timeouts are release gates.

## Verification baseline

- Web and database suite: 56 files and 648 tests passed against disposable
  PostgreSQL 16 with no skips. TypeScript, the production build, and both full
  and production-only dependency audits passed with zero vulnerabilities.
- Native suite: 484 tests passed with 2 opt-in live tests skipped under normal
  and strict concurrency plus warnings-as-errors. Thread Sanitizer passed the
  same 484-test suite with one additional documented process-harness skip and no
  race report.
- Operations passed 62/62, frontend recovery 6/6, credential rotation 19/19,
  and systemd contracts 2/2. Secret-scanner self-tests passed 22/22 and the
  repository scan was clean; ruleset/release-environment fixtures passed 5/5
  and 10/10. The real pinned Caddy image accepted the production config.
- The current app and DMG rebuilt successfully as universal arm64+x86_64; the
  ad-hoc hardened-runtime signature, single-instance metadata, and DMG checksum
  verified. Public Developer ID signing and notarization remain external gates.

## External boundary

Code-level readiness does not prove public release readiness. DNS/deployment,
GitHub governance settings, Apple Developer ID/notarization credentials, pager
delivery, offsite recovery custody, and a timed cross-host RTO drill require
owner-controlled systems and separate evidence.
