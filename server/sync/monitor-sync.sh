#!/usr/bin/env bash
set -euo pipefail

# Stateless external probe suitable for cron, systemd timers, or a hosted
# monitor. It prints one bounded JSON record and never includes response bodies,
# credentials, query strings, or client data.

BASE_URL="${ADDRESS_ATLAS_MONITOR_BASE_URL:-${1:-}}"
TIMEOUT_SECONDS="${ADDRESS_ATLAS_MONITOR_TIMEOUT_SECONDS:-10}"
CURL_BIN="${CURL_BIN:-curl}"

origin_pattern='^https://(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?)(:([0-9]{1,5}))?$'
if [[ -z "$BASE_URL" || "$BASE_URL" == *[[:space:]]* || ! "$BASE_URL" =~ $origin_pattern ]]; then
  echo 'Usage: ADDRESS_ATLAS_MONITOR_BASE_URL=https://sync.example.com monitor-sync.sh' >&2
  exit 64
fi
origin_port="${BASH_REMATCH[4]:-}"
if [[ -n "$origin_port" ]] && ((10#$origin_port < 1 || 10#$origin_port > 65535)); then
  echo 'ADDRESS_ATLAS_MONITOR_BASE_URL has an invalid HTTPS port.' >&2
  exit 64
fi
if [[ ! "$TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ || "$TIMEOUT_SECONDS" -gt 60 ]]; then
  echo 'ADDRESS_ATLAS_MONITOR_TIMEOUT_SECONDS must be an integer from 1 through 60.' >&2
  exit 65
fi
command -v "$CURL_BIN" >/dev/null 2>&1 || {
  echo 'curl is required.' >&2
  exit 69
}

started="$(date +%s)"

probe() {
  local path="$1"
  local expected="$2"
  local output
  if ! output="$("$CURL_BIN" \
    --silent \
    --show-error \
    --fail-with-body \
    --location \
    --max-redirs 0 \
    --max-filesize 4096 \
    --connect-timeout "$TIMEOUT_SECONDS" \
    --max-time "$TIMEOUT_SECONDS" \
    --header 'accept: application/json' \
    --write-out $'\n%{http_code}' \
    "${BASE_URL}${path}" 2>/dev/null)"; then
    return 1
  fi
  local status="${output##*$'\n'}"
  local body="${output%$'\n'*}"
  [[ "$status" == "200" && "$body" == "$expected" ]]
}

live_ok=false
ready_ok=false
probe /livez '{"ok":true,"service":"address-atlas-sync"}' && live_ok=true
probe /healthz '{"ok":true,"service":"address-atlas-sync"}' && ready_ok=true

finished="$(date +%s)"
duration_ms=$(((finished - started) * 1000))
status="unhealthy"
exit_code=2
if [[ "$live_ok" == true && "$ready_ok" == true ]]; then
  status="healthy"
  exit_code=0
elif [[ "$live_ok" == true ]]; then
  status="not_ready"
  exit_code=1
fi

printf '{"timestamp":"%s","service":"address-atlas-sync","status":"%s","live":%s,"ready":%s,"durationMs":%d}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$status" "$live_ok" "$ready_ok" "$duration_ms"
exit "$exit_code"
