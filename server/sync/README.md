# Address Atlas Sync Server

This folder is the production deployment target for the public native macOS app.

It runs only the zero-knowledge sync/auth surface:

- `GET /config/native`
- `GET /healthz`
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

`NATIVE_ENDPOINT_CONFIG_JSON` can adjust paths on the bundled public blockchain provider origins without shipping a new Mac app. It cannot change provider origins. The CoinGecko price endpoint is fixed to its bundled origin and path. Exchange hosts, methods, and paths are security-sensitive and remain a fixed allowlist inside the signed Mac app; the server cannot override them.

Example:

```env
NATIVE_ENDPOINT_CONFIG_VERSION=4
NATIVE_ENDPOINT_CONFIG_JSON={"chains":{"ethereum":{"rpcUrl":"https://eth.llamarpc.com/rpc"}}}
```

Generate `SYNC_SESSION_SECRET` with at least 32 random bytes. The server enforces configurable total-account capacity, persistent per-account daily encrypted-upload quotas, and an atomic aggregate encrypted-snapshot storage ceiling (`SYNC_GLOBAL_VAULT_STORAGE_LIMIT`, 10 GB by default) in addition to short-window request throttles.
