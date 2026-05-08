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

`NATIVE_ENDPOINT_CONFIG_JSON` can be used to update public client endpoint config without shipping a new Mac app. The Mac app still sends blockchain, price, and exchange requests directly from the client; this endpoint only tells it which public providers to use.
