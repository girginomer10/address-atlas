# Address Atlas Production Operations

This runbook is the production contract for the encrypted sync service. The
service is zero-knowledge, but its passkey records, opaque vault availability,
and account lifecycle still require normal production-grade recovery and
incident discipline.

## Reliability Objectives

- External probes run every minute against both `/livez` and `/healthz`.
- The external paging system opens exactly one incident after three
  consecutive nonzero monitor executions. One or two failures do not page. A
  healthy execution after an open incident sends one recovery notification and
  resets the streak. A failed `/livez` is an edge/process outage; a healthy
  `/livez` with failed `/healthz` is a configuration, database, or
  schema-readiness incident.
- Encrypted, signed backups use five-hour calendar slots with up to 15 minutes
  of jitter, keeping the longest scheduled gap at 5 hours 15 minutes and below
  the 6-hour RPO. The required offsite hook must copy the complete four-file
  artifact set to independently controlled immutable storage after each
  successful run.
- Weekly isolated restore drills target an RTO of 60 minutes. The drill must
  restore into a temporary database and validate the complete schema without
  replacing production.
- Docker logs are bounded to 10 files of 10 MB per service. Caddy access logs
  are JSON; exact IPs, authentication headers, cookies, and auth callback query
  values are removed or masked before they reach the log stream.
- Caddy and application/admin containers use read-only root filesystems,
  non-executable bounded `/tmp`, and the minimum capability set. Every service
  has a PID ceiling and memory limit/reservation; the reviewed defaults are
  Caddy 256 MB, web 1 GB, admin migration 768 MB, database-admin jobs 256 MB,
  and PostgreSQL 2 GB. Alert at sustained 80% memory or PID utilization and
  change an `ADDRESS_ATLAS_*_MEMORY_*` override only from measured high-water
  evidence, never merely to suppress an exhaustion incident.

These are minimum objectives. A larger user base should shorten the backup
interval and move encrypted copies to object storage with independent
retention and access control.

## One-Time Host Setup

1. Install Docker Engine with the Compose plugin, `age`/`age-keygen`, `curl`,
   and Git. Restrict Docker and backup access to operators.
2. Place the checkout at `/opt/address-atlas`. Production deployment accepts
   only a clean Git revision and tags the image with its exact 40-character
   commit SHA.
3. Generate independent schema-owner, cluster-admin, runtime, and session
   secrets:

   ```bash
   openssl rand -hex 32
   openssl rand -hex 32
   openssl rand -hex 32
   openssl rand -base64 48
   ```

4. Create the backup encryption identity and a separate manifest-signing key
   pair outside the repository:

   ```bash
   install -d -m 0700 /root/.config/address-atlas
   install -d -m 0700 /var/backups/address-atlas
   install -d -m 0700 /var/lib/address-atlas
   install -d -m 0700 /var/lib/address-atlas/deploy-sources
   install -d -m 0700 /var/lib/address-atlas/service-control
   age-keygen -o /root/.config/address-atlas/backup.agekey
   chmod 0600 /root/.config/address-atlas/backup.agekey
   age-keygen -y /root/.config/address-atlas/backup.agekey
   openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 \
     -out /root/.config/address-atlas/backup-signing-private.pem
   openssl pkey \
     -in /root/.config/address-atlas/backup-signing-private.pem \
     -pubout \
     -out /root/.config/address-atlas/backup-signing-public.pem
   chmod 0600 /root/.config/address-atlas/backup-signing-private.pem
   chmod 0644 /root/.config/address-atlas/backup-signing-public.pem
   ```

   Put only the printed age public recipient in
   `ADDRESS_ATLAS_BACKUP_AGE_RECIPIENT`. Keep a separately protected recovery
   copy of the age identity and signing public key; never place the age identity
   or signing private key beside off-host backups. Configure a root-owned,
   non-group-writable executable in `ADDRESS_ATLAS_BACKUP_OFFSITE_HOOK`. It must
   durably upload all four paths it receives and return nonzero on any failure.
5. Copy `server/sync/.env.production.example` to a root-owned file such as
   `/etc/address-atlas/sync.env` with mode `0600`. Fill every placeholder. The
   schema-owner, isolated cluster-admin, and runtime database passwords must all
   be different.
6. Point the wrapper at that file and validate without starting services:

   ```bash
   export ADDRESS_ATLAS_PROD_ENV_FILE=/etc/address-atlas/sync.env
   bash server/sync/manage-prod.sh config
   ```

7. For a new or legacy cluster, leave
   `ADDRESS_ATLAS_DATABASE_ROLE_MODE=bootstrap` for exactly one successful
   deploy. The bootstrap converts PostgreSQL's original bootstrap login into the
   isolated `address_atlas_admin`, creates a non-superuser `address_atlas`
   object owner, transfers ownership, and provisions `address_atlas_runtime`.
   Immediately change the setting to `steady`; strict release checks reject
   `bootstrap`, and every later deploy authenticates only as the isolated admin.

The long-running web container receives only `SYNC_DATABASE_URL`, which names
the `address_atlas_runtime` role. The schema-owner URL is passed only to the
profile-gated migration job; the isolated superuser is passed only to the
profile-gated role-provisioning job. Steady provisioning never receives the
owner password, so failed admin authentication cannot fall back to the owner.
The wrapper verifies exact table/sequence/schema/default privileges and fails if
the runtime role can create objects or has unauthorized DDL/DML rights.

## Deploy And Roll Back

Deploy only a clean, reviewed revision:

```bash
export ADDRESS_ATLAS_PROD_ENV_FILE=/etc/address-atlas/sync.env
npm run sync:prod:up
```

The wrapper takes one host-wide operations lock before reading deployment
state, copies the production environment into an owner-only locked snapshot,
and requires a clean `main` checkout at the freshly fetched `origin/main` SHA.
It exports that exact commit through `git archive` into a private, read-only
source cache. Docker build context, Compose/Caddy host paths, recovery hooks,
and native-config state logic all run from that byte- and metadata-verified
tree; later working-checkout changes cannot alter an in-flight deployment.
After a successful cutover, obsolete source trees are safely removed; the
current and directly captured rollback revisions remain available. Every cache
is reproducible from its authorized Git commit and contains no runtime data.

It then protects the existing volumes and classifies the source database before mutation. Only a provably untouched
database with no non-system objects or large objects may skip the pre-deploy
backup on its first installation. Every existing or ambiguous database requires
a fresh signed, decrypt-verified backup tied to the running web/PostgreSQL image
provenance. The wrapper then builds the SHA-tagged image, runs locked migrations,
verifies the DML-only role, and finally replaces the services. If any gate fails,
the new web image is not started.

A first installation journals `candidate-ready`, `schema-ready`, and
`roles-ready` with the exact revision, image ID, and PostgreSQL volume. If the
host or command stops, check out that recorded revision on local `main` and rerun
the same `sync:prod:up` command; it resumes only when that revision remains an
ancestor of current `origin/main`. Never delete or edit the journal to force a
retry.

After deployment, verify all three public boundaries:

```bash
curl --fail --silent https://sync.example.com/livez
curl --fail --silent https://sync.example.com/healthz
curl --fail --silent https://sync.example.com/config/native
```

After startup, the wrapper checks exact public `/livez`, `/healthz`, and native
configuration contracts. Failure automatically restores the captured prior web
image and revision while still returning a deployment failure; if no proven
rollback image exists, Caddy/web are stopped rather than serving an unverified
release. Numbered database migrations remain forward-applied, so every migration
must remain compatible with the prior web revision. For a manual rollback, use a
clean checkout of the known-good SHA and the same `sync:prod:up` gate. Never use
`latest`, force-push, or bypass backup/schema checks.

Database restore is a separate destructive operation and is not the normal
way to roll back application code.

An installation upgraded from a release that predates the native-config receipt
will refuse to deploy. With the known-good release still running, first ask the
break-glass command to print the exact confirmation, then repeat it verbatim:

```bash
bash server/sync/manage-prod.sh adopt-native-config --confirm ADOPT:inspect
bash server/sync/manage-prod.sh adopt-native-config \
  --confirm 'ADOPT:<reported-revision>:<reported-version>:<reported-sha256>'
```

Adoption is allowed only for a known commit that is an ancestor of the freshly
fetched `origin/main`, an exact running image/revision pair, and the config
fingerprint served publicly by that same revision. It cannot overwrite an
existing receipt.

## Rotate Database Credentials

Rotate the owner, isolated admin, and runtime credentials only as one operation.
The reviewed path requires `steady` role mode, one running provenance-bound
web/Caddy pair, and a fresh encrypted backup that decrypts and verifies before
the frontend is stopped.

```bash
export ADDRESS_ATLAS_PROD_ENV_FILE=/etc/address-atlas/sync.env
umask 077
install -m 0600 "$ADDRESS_ATLAS_PROD_ENV_FILE" \
  "$ADDRESS_ATLAS_PROD_ENV_FILE.next"
# In .next, change only these five fields, using three new mutually distinct
# role secrets that are also distinct from all three old values:
# POSTGRES_PASSWORD, POSTGRES_ADMIN_PASSWORD, POSTGRES_RUNTIME_PASSWORD,
# SYNC_SCHEMA_DATABASE_URL, SYNC_DATABASE_URL
next_sha="$(sha256sum "$ADDRESS_ATLAS_PROD_ENV_FILE.next" | awk '{print $1}')"
npm run sync:credentials:rotate -- \
  "$ADDRESS_ATLAS_PROD_ENV_FILE.next" --confirm \
  "ROTATE-DATABASE-CREDENTIALS:${next_sha}"
```

The host lock covers backup, the atomic PostgreSQL transaction, environment
replacement, and public smoke. A nonsecret `prepared` → `database-committed` →
`environment-committed` → `service-verified` journal binds the exact A/B file
hashes, operation source revision, recovery-tool hashes (including the exact
immutable backup implementation), backup digest/path,
served revision, image, containers, and PostgreSQL volume. Database URLs may
retain required remote TLS parameters such as `sslmode=verify-full`, but their
complete non-credential protocol/host/port/path/query contract must be
byte-identical in A and B.
The command rejects `ADDRESS_ATLAS_BACKUP_SCRIPT` overrides. Rotation Compose
commands run inside a positive environment allowlist, so inherited domain,
role-mode, credential, URL, or native-config values cannot outrank the locked
environment files. PostgreSQL connect, statement, and lock deadlines are fixed
at 5, 60, and 10 seconds respectively; the database-rotation worker has a
120-second outer deadline. After the atomic role changes, every pre-existing
session for the owner, admin, and runtime roles is terminated and absence is
verified before old-password rejection counts as successful.
Environment replacement writes a `0600` same-directory temporary file, fsyncs
it, renames it, and fsyncs the directory. The old web/Caddy identities are
stopped exactly; the same immutable web image and revision are recreated with B
and must pass public smoke before the journal is removed. The `.next` file is
consumed only after service verification. A resumed `service-verified` journal
rechecks the current exact Caddy/web identity, image, revision, and public smoke
before cleanup. Any partial restart, identity mismatch, or smoke failure stops
all fixed-project Caddy/web containers and retains the journal for recovery.

If power or the process stops, reclaim the operations lock only through the
documented stale-owner procedure, then rerun the exact command with the same
`.next` file and confirmation from the exact journaled source revision. A source
update or change to `manage-prod.sh`, the state tool, Compose contract, role
provisioner, or backup tool is rejected until the existing operation is
completed with its original toolchain. Other stateful operations remain
blocked while the journal exists. Never edit or delete the journal, never
rotate one role in isolation, and never restart the A-configured frontend after
the database phase may have committed.

## Automated Backup, Restore Drill, And Monitoring

Install the supplied unit templates after reviewing paths for the host. The
stateless monitor also requires Python 3 for a monotonic sub-second total
deadline shared by both probes:

```bash
cp server/sync/systemd/address-atlas-*.service /etc/systemd/system/
cp server/sync/systemd/address-atlas-*.timer /etc/systemd/system/
printf '%s\n' 'ADDRESS_ATLAS_MONITOR_BASE_URL=https://sync.example.com' \
  > /etc/address-atlas/monitor.env
chmod 0600 /etc/address-atlas/monitor.env
systemctl daemon-reload
systemctl enable --now \
  address-atlas-backup.timer \
  address-atlas-restore-drill.timer \
  address-atlas-monitor.timer
```

Send failed systemd units and nonzero monitor exits to the operator's paging
system. The paging rule—not this stateless probe—owns the consecutive-failure
counter. Production release is blocked until a controlled integration test has
produced three consecutive nonzero monitor results, exactly one incident alert,
then a healthy result and exactly one recovery notification. Retain the fired
test event IDs or screenshots, UTC timestamps, routing destination, and paging
rule version with the release evidence. Confirm the timers and their last
results:

```bash
systemctl list-timers 'address-atlas-*'
systemctl status address-atlas-backup.service
systemctl status address-atlas-restore-drill.service
systemctl status address-atlas-monitor.service
```

Manual equivalents are:

```bash
npm run sync:backup
npm run sync:backup:verify
npm run sync:restore:drill
ADDRESS_ATLAS_MONITOR_BASE_URL=https://sync.example.com npm run sync:monitor
```

A valid backup set has four files with the same base name:

- `*.dump.age`: streaming `pg_dump` custom format encrypted by age;
- `*.dump.age.sha256`: encrypted-file integrity checksum;
- `*.dump.age.manifest.json`: canonical creation time, database, encrypted byte
  size/digest, exact running web revision/image, PostgreSQL image, and numbered
  migration-ledger identity, plus the exact native-config version, digest,
  timestamp, and serving revision that clients could observe at snapshot time;
- `*.dump.age.manifest.sig`: detached RSA/SHA-256 signature over the canonical
  manifest.

Plaintext dumps are never written to the host. Verification requires the trusted
public-key signature, exact canonical manifest, checksum/size/provenance and
migration-ledger contract, successful decryption, and `pg_restore --list`.
`ADDRESS_ATLAS_BACKUP_MAX_BYTES` bounds both locally created and externally
retrieved payloads before copying or decryption (50 GiB in the production
template). External artifacts are snapshotted through no-follow, descriptor-
verified, size-bounded reads inside the private backup directory; their source
paths are never consumed directly after verification.
Recovery proof additionally requires a fresh-template restore drill. When
`ADDRESS_ATLAS_BACKUP_OFFSITE_REQUIRED=true`, local backup success is not
reported unless the complete artifact set is accepted by the offsite hook; a
delivery failure preserves the completed local copy for incident handling.
The drill runs migrations and the same runtime privilege contract against its
isolated database, while proving the live cluster-global role attributes and
credentials without rewriting them. Hook staging stays inside the private
backup directory so it remains visible to the host Docker daemon even under the
unit's `PrivateTmp=true` sandbox.

## Production Restore

1. Confirm the selected backup, sidecars, age identity, incident authorization,
   and business owner approval.
2. Stop only the public edge and web process, leaving PostgreSQL available:

   ```bash
   bash server/sync/manage-prod.sh maintenance
   ```

3. Run one final isolated drill against the exact backup.
4. Authorize and execute the restore with both independent gates:

   ```bash
   export ADDRESS_ATLAS_ALLOW_PRODUCTION_RESTORE=YES_I_UNDERSTAND_DATA_WILL_BE_REPLACED
   npm run sync:restore:production -- \
     /absolute/path/address-atlas-YYYYMMDDTHHMMSSZ.dump.age \
     --confirm RESTORE:address_atlas_sync
   ```

The wrapper verifies the selected signed artifact, builds both the exact current
image and the captured rollback image, and privately validates their native
configuration before stopping the frontend. It creates and verifies a fresh
safety backup, restores into a new `template0` staging database with no
owner/privilege replay, applies the exact current migration/readiness hook, and
atomically renames the old database into quarantine and the candidate into
production. Before runtime LOGIN is restored, the same reviewed provisioning
path establishes exact ownership and ACLs. The wrapper then privately validates
current and N-1 compatibility again, deploys the current web revision, runs all
public smoke checks, and writes the durable config receipt.

A failed or ambiguous cutover/provisioning recovery keeps the web tier stopped
and preserves the operation lock for investigation; a proven pre-cutover or
post-cutover failure restores the prior database name where safe. Never bypass
that stale lock until the database names, runtime LOGIN state, and safety backup
have been independently reconciled. After success, verify a real passkey
upload/download flow and retain the quarantined database until incident closure
and an independently verified backup exist.

## Fresh-Cluster And Full-Host Recovery

Normal production restore deliberately requires the existing protected role
topology and a verified rollback release. Use the separately gated
`bootstrap-restore` path only after the original PostgreSQL storage is lost and
the replacement cluster is provably pristine. It rejects legacy schema-v3
artifacts because only schema v4 cryptographically binds the last client-visible
native-config high-water mark.

Before an incident, keep these recovery dependencies outside the production
host and test their retrieval:

- every four-file encrypted backup set in immutable offsite storage, with an
  operator procedure for selecting and downloading one complete set;
- the age identity and the manifest-signing **public** key in separately
  protected recovery storage (the online signing private key is not required to
  restore an existing artifact);
- an encrypted copy of the production environment and native endpoint policy,
  including fresh-host database-role secrets and the session secret;
- the stable WebAuthn RP domain, DNS control, and a way to reissue ACME/TLS
  certificates for that same hostname;
- an independent Git/source mirror and availability of every pinned container,
  Node, Swift/Xcode, and recovery-tool dependency needed by the reviewed current
  revision. Manifest image IDs prove provenance; they are not downloadable image
  archives;
- replacement credentials for the offsite uploader, monitoring, release, and
  other host-bound integrations.

On the replacement host, restore the clean current `main` checkout and private
environment, keep `ADDRESS_ATLAS_DATABASE_ROLE_MODE=steady`, retrieve one
complete v4 backup set, and prepare the exact documented stable PostgreSQL
volume. Then run both independent gates:

```bash
export ADDRESS_ATLAS_ALLOW_BOOTSTRAP_RESTORE=YES_I_UNDERSTAND_FRESH_CLUSTER_ONLY
npm run sync:restore:bootstrap -- \
  /absolute/path/address-atlas-YYYYMMDDTHHMMSSZ.dump.age \
  --confirm BOOTSTRAP-RESTORE:address_atlas_sync
```

The wrapper verifies and snapshots the signed artifact before mutation, binds
the current candidate config to the signed high-water mark, and accepts only a
fresh PostgreSQL 16 cluster with the exact built-in role/database topology. It
restores and migrates into staging, performs the one-way admin/owner/runtime role
split, atomically quarantines the original empty database, then starts the
current web release. Completion is not acknowledged until public liveness,
readiness, native-config provenance, and the durable current config receipt all
pass. A crash retains exact artifact/storage/phase/target-toolchain state. After
independently confirming that the recorded lock owner and its process group are
dead, authorize one compare-and-swap reclaim and rerun the identical artifact:

```bash
export ADDRESS_ATLAS_ALLOW_BOOTSTRAP_LOCK_RECLAIM=YES_I_VERIFIED_STALE_OWNER
export ADDRESS_ATLAS_EXPECTED_BACKUP_SHA256=<sha256 printed by signed inspect>
npm run sync:restore:bootstrap -- \
  /absolute/path/address-atlas-YYYYMMDDTHHMMSSZ.dump.age \
  --confirm BOOTSTRAP-RESTORE:address_atlas_sync
```

The reclaim validates the signed artifact digest, PostgreSQL storage identity,
database, and stale process identity before it runs. If `origin/main` advanced
during the incident, recovery remains pinned to its recorded target: keep or
restore local `main` at the exact revision reported by the wrapper; that commit
must still be an ancestor of current `origin/main`. Do not resume from an
arbitrary older commit or silently upgrade the recovery toolchain mid-state.
Never delete a recovery marker or change the selected volume to force progress.

After recovery, verify a real passkey sign-in and encrypted upload/download,
rotate host-bound credentials, create and deliver a new signed backup, and keep
the quarantined empty database until incident closure. A database bootstrap
test alone is not a 60-minute full-host RTO proof: run a timed, isolated
cross-host exercise that includes backup retrieval, DNS/TLS, source/image
availability, public smoke, and operator paging at least quarterly.

## Registration And Account Lifecycle

Production registration is closed by default. For a controlled enrollment
window, set `SYNC_REGISTRATION_ENABLED=true`, keep the durable hourly limit
small, deploy, enroll the intended accounts, set it back to `false`, and deploy
again. Registration options and verification both re-check the kill switch;
turning it off invalidates an in-progress admission.

- `DELETE /account/session` revokes the bearer session represented by the
  Authorization header.
- `DELETE /account` requires a bearer session issued by passkey authentication
  within the last five minutes plus
  `X-Address-Atlas-Confirm: delete-account`; database cascades delete passkeys,
  sessions, quota rows, and the opaque snapshot while preserving the global
  byte-counter invariant. A pre-database global/client limiter also bounds
  unauthenticated idempotency-receipt probes and returns `429` with
  `Retry-After: 60` before any receipt lookup.

Treat account deletion as irreversible. The server cannot decrypt or recover a
deleted vault; the user must retain a local recovery kit.

## Incident Playbooks

### Liveness fails

- Confirm DNS/TLS and host reachability, then inspect the bounded Caddy/web
  container logs. Logs must remain JSON and must not contain raw bearer tokens,
  callback state, cookies, or exact client IPs.
- If the public process is unsafe, `npm run sync:prod:down` stops only
  containers carrying the fixed Address Atlas Compose project label and leaves
  containers/volumes recoverable. It also durably publishes a private
  `/var/lib/address-atlas/service-control/emergency-stop` fence before the
  verified stop pass. Every later production service start/create rechecks that
  fence under the same short cutover lock, so a backup, build, restore, or
  credential rotation that was already in flight cannot recreate the project
  after `down` succeeds. The long backup/restore operation lock is deliberately
  not required for the immediate stop.
- Keep the fence active through incident review. After verifying Docker state
  and recovering/removing any separately verified stale operation or
  `service-control.lock`, clear it only under the normal host operation lock:

  ```bash
  bash server/sync/manage-prod.sh clear-emergency-stop \
    --confirm CLEAR-EMERGENCY-STOP:address-atlas-sync
  ```

  Clearing refuses while any fixed-project container is running. A subsequent
  `up` still performs all normal backup, provenance, migration, and smoke gates.

### Readiness fails but liveness passes

- Check PostgreSQL health, disk capacity, runtime role privileges, schema
  bootstrap output, and configuration diagnostics.
- Do not make Caddy depend on deep readiness; that would turn a database blip
  into a proxy-wide 502. Keep traffic handling and alerting separate.

### Session or server secret exposure

- Close registration immediately.
- Rotate `SYNC_SESSION_SECRET` to invalidate all bearer tokens and redeploy.
- If a database password is implicated, enter maintenance and keep the web tier
  stopped. Normal deployment deliberately refuses implicit owner, admin, or
  runtime credential rotation because a crash between the database change and
  container replacement could strand production. Use a separately reviewed,
  resumable rotation procedure with old/new recovery credentials and a verified
  backup; do not edit the production env file and rerun `up` as a shortcut.
- Review privacy-safe diagnostic IDs and timestamps; do not copy raw production
  logs or user data into tickets, handoff notes, or semantic memory.

### Storage or abuse pressure

- Keep the per-account daily ingress, global daily ingress, account-capacity,
  and aggregate stored-byte limits enabled. Rejected authenticated PUT bodies
  still consume ingress allowance.
- Do not raise limits until disk headroom, backup duration, restore duration,
  and abuse cost have been reviewed together.
