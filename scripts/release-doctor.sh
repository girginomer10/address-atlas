#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STRICT=0
if [[ "${1:-}" == "--strict" ]]; then
  STRICT=1
fi

failures=0
warnings=0

pass() {
  printf 'PASS %s\n' "$1"
}

warn() {
  warnings=$((warnings + 1))
  printf 'WARN %s\n' "$1"
}

fail() {
  failures=$((failures + 1))
  printf 'FAIL %s\n' "$1"
}

has_command() {
  command -v "$1" >/dev/null 2>&1
}

cd "$ROOT"

has_command swift && pass "Swift toolchain found" || fail "Swift toolchain missing"
has_command docker && pass "Docker found" || warn "Docker missing; VPS compose config cannot be checked locally"
has_command security && pass "macOS security tool found" || warn "macOS security tool missing"

if has_command xcodebuild; then
  xcodebuild -license check >/dev/null 2>&1 && pass "Xcode license accepted" || fail "Xcode license not accepted"
else
  fail "xcodebuild missing"
fi

codesigning_identities=""
if has_command security; then
  codesigning_identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
fi
if grep -q "Developer ID Application" <<< "$codesigning_identities"; then
  pass "Developer ID Application signing identity available"
else
  fail "Developer ID Application signing identity missing; public notarized release is blocked"
fi

if [[ -f server/sync/.env.production ]]; then
  pass "server/sync/.env.production exists"
  if has_command docker; then
    docker compose --env-file server/sync/.env.production -f server/sync/compose.prod.yml config >/dev/null \
      && pass "Production compose config parses" \
      || fail "Production compose config does not parse"
  fi
else
  warn "server/sync/.env.production missing; copy server/sync/.env.production.example before VPS deploy"
fi

for name in ADDRESS_ATLAS_CODESIGN_IDENTITY ADDRESS_ATLAS_NOTARY_PROFILE; do
  if [[ -n "${!name:-}" ]]; then
    pass "$name is set"
  else
    fail "$name is not set; public release is blocked"
  fi
done

if [[ -n "${ADDRESS_ATLAS_CODESIGN_IDENTITY:-}" ]]; then
  if grep -Fq "$ADDRESS_ATLAS_CODESIGN_IDENTITY" <<< "$codesigning_identities"; then
    pass "Selected signing identity exists in Keychain"
  else
    fail "Selected signing identity was not found in Keychain"
  fi
fi

if [[ -n "${ADDRESS_ATLAS_NOTARY_PROFILE:-}" && "$STRICT" -eq 1 ]]; then
  if xcrun notarytool history --keychain-profile "$ADDRESS_ATLAS_NOTARY_PROFILE" >/dev/null 2>&1; then
    pass "Selected notary profile is valid"
  else
    fail "Selected notary profile is missing, invalid, or cannot reach Apple's notary service"
  fi
fi

live_exchange_missing=0
for name in \
  ADDRESS_ATLAS_BINANCE_API_KEY \
  ADDRESS_ATLAS_BINANCE_SECRET \
  ADDRESS_ATLAS_COINBASE_API_KEY \
  ADDRESS_ATLAS_COINBASE_SECRET \
  ADDRESS_ATLAS_KRAKEN_API_KEY \
  ADDRESS_ATLAS_KRAKEN_SECRET; do
  [[ -n "${!name:-}" ]] || live_exchange_missing=1
done

if [[ "$live_exchange_missing" -eq 0 ]]; then
  pass "Live exchange smoke credentials are present"
else
  warn "Live exchange smoke credentials are incomplete"
fi

printf '\nRelease doctor: %d failure(s), %d warning(s).\n' "$failures" "$warnings"

if [[ "$STRICT" -eq 1 && "$failures" -gt 0 ]]; then
  exit 1
fi
