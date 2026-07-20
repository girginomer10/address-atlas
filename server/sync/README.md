# Address Atlas Sync Server

This folder is the production deployment target for the public native macOS app.

It runs only the zero-knowledge sync/auth surface:

- `GET /config/native`
- `GET /livez`
- `GET /healthz`
- `GET /auth/native`
- `POST /auth/passkey/options`
- `POST /auth/passkey/verify`
- `GET /vault/latest`
- `PUT /vault/latest`

The server stores passkey public credentials and encrypted vault snapshots. It does not receive the Mac vault key, recovery material, wallet balances in plaintext, exchange credentials in plaintext, or scan history in plaintext.

## Deploy

```bash
cp server/sync/.env.production.example server/sync/.env.production
npm run sync:prod:up
```

`npm run sync:prod:up` performs a non-destructive volume preflight. New
installations use stable global names for PostgreSQL data, Caddy's ACME account
and certificates, and Caddy configuration. Upgrades from either historical
Compose layout automatically reconnect each single existing project-scoped
volume instead of creating empty state. If more than one candidate exists for
a role, deployment fails closed and prints every candidate; inspect them and
set the corresponding `ADDRESS_ATLAS_POSTGRES_VOLUME`,
`ADDRESS_ATLAS_CADDY_DATA_VOLUME`, or `ADDRESS_ATLAS_CADDY_CONFIG_VOLUME` in
`server/sync/.env.production` to the authoritative one. Nothing is copied,
renamed, or deleted automatically. Preview all selections at any time with:

```bash
npm run sync:prod:volume
```

Validate the fully interpolated Compose configuration through the same volume
preflight without starting or changing containers with:

```bash
bash server/sync/manage-prod.sh config
```

The preflight also fails if it sees the same Compose logical volume label under
an unrecognized project name. This can be an older Address Atlas deployment
started with a custom `--project-name`, but `caddy-data` and `caddy-config` are
also common in unrelated stacks, so the helper deliberately cannot infer
ownership. This conservative check can block a clean installation on a Docker
host that already runs another Caddy stack. Inspect the reported volumes. If
one belongs to Address Atlas, set the corresponding override to that existing
name. If none does and this is a confirmed new installation, set only the
reported role's override to its exact documented stable name to acknowledge
that a new volume should be created. A different nonexistent override is not an
acknowledgement and remains blocked, protecting upgrades from simple name
typos. Any intentional custom name must already exist before it is selected;
the wrapper only creates the documented stable names. Unscoped matches are
never adopted automatically.

The `config` command reads `server/sync/.env.production` when present. CI may
instead provide every required value in its environment when that default file
does not exist. An explicitly selected `ADDRESS_ATLAS_PROD_ENV_FILE` must exist.

Do not run the production Compose file directly during an upgrade: the wrapper
is what protects installations whose environment file predates the stable
volume name.

Before `up`, the wrapper also checks every selected volume's running mounts. It
allows only the fixed `address-atlas-sync` project and the expected service;
an active legacy, custom-project, or unlabeled container fails closed. Stop the
old stack cleanly before retrying so two PostgreSQL processes can never share
one data directory. The wrapper pins the Compose project name explicitly, so a
shell or environment-file `COMPOSE_PROJECT_NAME` cannot redirect deployment.

`NATIVE_ENDPOINT_CONFIG_JSON` can adjust paths on the bundled public blockchain provider origins without shipping a new Mac app. It cannot change provider origins. The CoinGecko price endpoint is fixed to its bundled origin and path. Exchange hosts, methods, and paths are security-sensitive and remain a fixed allowlist inside the signed Mac app; the server cannot override them.

Example:

```env
NATIVE_ENDPOINT_CONFIG_VERSION=5
NATIVE_ENDPOINT_CONFIG_JSON={"chains":{"ethereum":{"rpcUrl":"https://ethereum-rpc.publicnode.com"}}}
```

The bundled endpoint set is revision 5. Existing production environment files
must set `NATIVE_ENDPOINT_CONFIG_VERSION` to at least `5`; the server rejects a
lower explicit value instead of publishing the v5 payload under a stale version.
Use a higher value whenever an operator override changes the published config.

Deploy-ordering invariant: the Mac client fails closed — both vault upload and
download surface a 503 — whenever `/config/native` is unreachable or serves a
`configVersion` lower than the client's bundled value (currently 5; see
`NativeEndpointConfig.swift` in the native package and
`src/lib/sync/native-config.ts`). Whenever a client release bumps its bundled
config version, raise `NATIVE_ENDPOINT_CONFIG_VERSION` on the server to at
least that new value and deploy the server BEFORE shipping the client.

`NATIVE_ENDPOINT_CONFIG_MESSAGE` is an optional operator notice served through
`/config/native` and displayed as a banner inside the Mac app. Leave it unset
outside of maintenance or advisory windows.

## Health Endpoints

- `GET /livez` is the lightweight edge liveness probe. It returns
  `{"ok":true,"service":"address-atlas-sync"}` without touching the database or
  configuration. Caddy's active health check targets it, so a Postgres blip
  cannot make the proxy mark the app down and 502 every route.
- `GET /healthz` is the deep readiness probe: database connectivity, required
  schema, passkey/secret/limit, and native endpoint configuration. The web
  container's Compose healthcheck and external monitoring use it.

In production, boot-time configuration validation runs via
`src/instrumentation.ts`: the container fails fast at start on a bad
`SYNC_SESSION_SECRET`, `PASSKEY_*`, or database configuration instead of
serving requests with invalid settings.

Generate `SYNC_SESSION_SECRET` with at least 32 random bytes. Generate the Postgres password with `openssl rand -hex 32` and use the same URL-safe value in `POSTGRES_PASSWORD` and `SYNC_DATABASE_URL`. `PASSKEY_ORIGIN` is derived as `https://ADDRESS_ATLAS_DOMAIN`; production startup and `/healthz` also verify the exact match, so Caddy cannot be healthy while WebAuthn ceremonies target a different host. The server rejects malformed explicit configuration and keeps `/healthz` unavailable until its database connection, required schema, passkey, secret, limit, and native endpoint settings are valid.

`SYNC_DB_POOL_SIZE`, `SYNC_DB_CONNECT_TIMEOUT_MS`,
`SYNC_DB_IDLE_TIMEOUT_MS`, `SYNC_DB_STATEMENT_TIMEOUT_MS`, and
`SYNC_DB_QUERY_TIMEOUT_MS` are forwarded to the web container. Keep the pool
small enough for the Postgres instance's connection limit.

The server enforces configurable total-account capacity, persistent per-account daily encrypted-upload quotas, and an atomic aggregate encrypted-snapshot storage ceiling (`SYNC_GLOBAL_VAULT_STORAGE_LIMIT`, 10 GB by default) in addition to short-window request throttles. Exact idempotent retries and rejected stale or same-version uploads consume daily byte quota but do not consume an additional logical-write allowance.

Caddy and the application independently cap request-body reads at 60 seconds;
Caddy also limits request-header reads to 10 seconds. These are absolute elapsed-time
deadlines, so do not raise them without reviewing slow-upload abuse exposure.
