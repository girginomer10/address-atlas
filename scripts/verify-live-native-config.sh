#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <https-origin> <app-version> <bundled-config-version> <source-commit> <probe-nonce> [expected-binding]" >&2
  exit 64
}

[[ "$#" -eq 5 || "$#" -eq 6 ]] || usage
ORIGIN="$1"
APP_VERSION="$2"
BUNDLED_CONFIG_VERSION="$3"
SOURCE_COMMIT="$4"
PROBE_NONCE="$5"
EXPECTED_BINDING="${6:-}"
CURL_BIN="${CURL_BIN:-curl}"
NODE_BIN="${NODE_BIN:-node}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
STATE_TOOL="${ROOT_DIR}/server/sync/native-config-deploy-state.mjs"

for command in "$CURL_BIN" "$NODE_BIN"; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Required live-config verification command is missing: ${command}" >&2
    exit 69
  }
done
[[ "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || {
  echo "Live-config source commit is malformed." >&2
  exit 65
}
[[ "$PROBE_NONCE" =~ ^[A-Za-z0-9._-]{1,200}$ ]] || {
  echo "Live-config probe nonce is malformed." >&2
  exit 65
}
"$NODE_BIN" -e '
  "use strict";
  const raw = process.argv[1];
  let url;
  try { url = new URL(raw); } catch { process.exit(1); }
  if (url.protocol !== "https:" || url.origin !== raw || url.port !== ""
      || url.username || url.password || url.pathname !== "/" || url.search || url.hash) {
    process.exit(1);
  }
' "$ORIGIN" || {
  echo "Production sync origin must be exactly https://<hostname> with no port, path, credentials, query, or fragment." >&2
  exit 65
}

temporary_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
[[ -d "$temporary_root" && ! -L "$temporary_root" ]] || {
  echo "Live-config verification temporary directory is unavailable." >&2
  exit 74
}
state_dir="$(mktemp -d "${temporary_root%/}/address-atlas-live-config.XXXXXX")"
cleanup() {
  rm -rf "$state_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
headers="$state_dir/headers"
body="$state_dir/body.json"

"$CURL_BIN" \
  --proto '=https' \
  --tlsv1.2 \
  --silent \
  --show-error \
  --fail \
  --max-redirs 0 \
  --max-filesize 1000000 \
  --connect-timeout 5 \
  --max-time 15 \
  --header 'accept: application/json' \
  --header 'cache-control: no-cache' \
  --dump-header "$headers" \
  --output "$body" \
  "${ORIGIN}/config/native?release_probe=${PROBE_NONCE}"

fingerprint="$("$NODE_BIN" "$STATE_TOOL" release-gate \
  "$APP_VERSION" "$BUNDLED_CONFIG_VERSION" < "$body")" || {
  echo "Production native config is incompatible with this client release." >&2
  exit 67
}
IFS='|' read -r config_version config_digest config_updated_at extra <<< "$fingerprint"
[[ -z "$extra" && "$config_version" =~ ^[0-9]+$ \
   && "$config_digest" =~ ^[0-9a-f]{64}$ \
   && "$config_updated_at" =~ ^[0-9]+$ ]] || {
  echo "Production native-config fingerprint is malformed." >&2
  exit 70
}

"$NODE_BIN" "$STATE_TOOL" verify-response \
  "$headers" "$config_digest" "$SOURCE_COMMIT" || {
  echo "Production native-config response lacks the exact no-store digest/revision receipt." >&2
  exit 67
}
binding="${config_version}|${config_digest}|${config_updated_at}|${SOURCE_COMMIT}"
if [[ -n "$EXPECTED_BINDING" && "$binding" != "$EXPECTED_BINDING" ]]; then
  echo "Production native config or serving revision changed during release assembly." >&2
  exit 67
fi
printf '%s\n' "$binding"
