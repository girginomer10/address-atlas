# Contributing to Address Atlas

Thank you for helping make Address Atlas safer, clearer, and more useful. Focused bug fixes, tests, documentation improvements, accessibility work, and well-scoped network or provider additions are welcome.

## Before you start

- Search existing issues before opening a new one.
- Use an issue for substantial behavior or architecture changes so the scope can be agreed before implementation.
- Report suspected vulnerabilities through [GitHub private vulnerability reporting](https://github.com/girginomer10/address-atlas/security/advisories/new), not a public issue.
- Never include real wallet inventories, exchange credentials, bearer tokens, passkeys, recovery material, private keys, production logs, or `.env` contents in an issue, test, commit, or pull request.

Address Atlas is deliberately read-only. Changes must not request or store seed phrases, wallet private keys, signing permission, trading permission, transfer permission, or withdrawal permission.

## Repository layout

- `native/AddressAtlasMac` — native SwiftUI product, core model, scanners, encryption, recovery, export, and sync client.
- `src` and `server/sync` — optional passkey-authenticated, client-encrypted sync service.
- `docs/DEVELOPMENT.md` — architectural invariants, local setup, and the complete verification gate.
- `docs/OPERATIONS.md` — production sync operations.
- `docs/RELEASE_CHECKLIST.md` — signed and notarized release contract.

## Local setup

For the native app:

```bash
cd native/AddressAtlasMac
./check-toolchain.sh
swift run AddressAtlasMac
```

For the optional sync service, install Node.js `>=22.17 <23`, npm
`>=10.9.2 <11`, and Docker with Compose:

```bash
cd "$(git rev-parse --show-toplevel)"
npm ci
install -m 0600 .env.example .env
node -e '
  const fs = require("node:fs"), crypto = require("node:crypto"), path = ".env";
  const source = fs.readFileSync(path, "utf8");
  fs.writeFileSync(path, source.replace(
    "replace-with-a-long-random-secret",
    crypto.randomBytes(32).toString("base64url"),
  ));
'
npm run sync:db:up
npm run dev
```

The setup creates `.env` with owner-only permissions and replaces the
deliberately rejected session-secret placeholder. Use locally generated secrets
in `.env` and never commit it. The repository rejects known secret and private-key
artifacts, but that guard is not a substitute for reviewing what you stage.

## Quality expectations

- Add or update tests for behavior changes and regressions.
- Preserve successful partial scan results and surface provider failures explicitly.
- Keep credential-bearing exchange origins, paths, and methods pinned in the native app.
- Keep plaintext portfolio data and exchange credentials out of the sync service.
- Treat unpriced assets as unpriced, not as successfully valued at zero.
- Preserve migration compatibility for persisted vault documents.
- Keep user-facing privacy and export claims consistent with actual code paths.

New networks, tokens, or providers should include validation, stable identity rules, bounded requests, failure behavior, and representative tests. Do not add a provider based only on a happy-path response.

## Verification

Run the checks relevant to your change. Common commands are:

```bash
npm test
npm run typecheck
npm run build

cd native/AddressAtlasMac
swift test
```

Full native tests require Xcode rather than Command Line Tools alone. Operations, release tooling, database changes, and concurrency-sensitive code have additional gates listed in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

Before opening a pull request:

```bash
git diff --check
python3 scripts/check-secret-artifacts.py
```

## Pull requests

Keep each pull request focused and explain:

1. The user or system problem.
2. The chosen solution and important tradeoffs.
3. The privacy, custody, provider, persistence, or release boundaries affected.
4. The exact checks you ran and any checks you could not run.

Screenshots are helpful for visible UI changes, but use synthetic data only. A passing CI run is required; it does not replace careful review of security and product claims.

By participating, you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).
