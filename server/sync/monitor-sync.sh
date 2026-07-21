#!/usr/bin/env bash
set -euo pipefail

# Stateless external probe suitable for cron, systemd timers, or a hosted
# monitor. It prints one bounded JSON record and never includes response bodies,
# credentials, query strings, or client data.

BASE_URL="${ADDRESS_ATLAS_MONITOR_BASE_URL:-${1:-}}"
MAX_TOTAL_TIMEOUT_SECONDS=20
TIMEOUT_SECONDS="${ADDRESS_ATLAS_MONITOR_TIMEOUT_SECONDS:-10}"
CURL_BIN="${CURL_BIN:-curl}"
MONOTONIC_BIN="${MONOTONIC_BIN:-python3}"

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
if [[ ! "$TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ \
    || "$TIMEOUT_SECONDS" -gt "$MAX_TOTAL_TIMEOUT_SECONDS" ]]; then
  echo 'ADDRESS_ATLAS_MONITOR_TIMEOUT_SECONDS is one total deadline and must be an integer from 1 through 20.' >&2
  exit 65
fi
command -v "$CURL_BIN" >/dev/null 2>&1 || {
  echo 'curl is required.' >&2
  exit 69
}
command -v "$MONOTONIC_BIN" >/dev/null 2>&1 || {
  echo 'python3 is required for the monotonic monitor deadline.' >&2
  exit 69
}

monotonic_ns() {
  "$MONOTONIC_BIN" -c \
    'import time; print(time.monotonic_ns())' 2>/dev/null
}

started_ns="$(monotonic_ns)" || exit 69
[[ "$started_ns" =~ ^[1-9][0-9]*$ ]] || exit 69
deadline_ns=$((started_ns + TIMEOUT_SECONDS * 1000000000))
duration_ms=0

curl_seconds_to_ms() {
  local raw="$1"
  [[ "$raw" =~ ^([0-9]+)(\.([0-9]{1,9}))?$ ]] || return 1
  local whole="${BASH_REMATCH[1]}"
  local fraction="${BASH_REMATCH[3]:-}"
  fraction="${fraction}000000000"
  fraction="${fraction:0:9}"
  local millis="${fraction:0:3}"
  local sub_millisecond="${fraction:3:6}"
  local result=$((10#$whole * 1000 + 10#$millis))
  if [[ "$sub_millisecond" == *[1-9]* ]]; then
    result=$((result + 1))
  fi
  printf '%d\n' "$result"
}

probe() {
  local path="$1"
  local expected="$2"
  local now_ns remaining_ns remaining output timing timed_ms response_without_timing curl_status=0
  now_ns="$(monotonic_ns)" || return 1
  [[ "$now_ns" =~ ^[1-9][0-9]*$ ]] || return 1
  remaining_ns=$((deadline_ns - now_ns))
  (( remaining_ns > 0 )) || return 1
  printf -v remaining '%d.%09d' \
    "$((remaining_ns / 1000000000))" "$((remaining_ns % 1000000000))"
  if output="$("$CURL_BIN" \
    --silent \
    --show-error \
    --fail-with-body \
    --location \
    --max-redirs 0 \
    --max-filesize 4096 \
    --connect-timeout "$remaining" \
    --max-time "$remaining" \
    --header 'accept: application/json' \
    --write-out $'\n%{http_code}\n%{time_total}' \
    "${BASE_URL}${path}" 2>/dev/null)"; then
    curl_status=0
  else
    curl_status=$?
  fi
  timing="${output##*$'\n'}"
  response_without_timing="${output%$'\n'*}"
  if timed_ms="$(curl_seconds_to_ms "$timing")"; then
    duration_ms=$((duration_ms + timed_ms))
  fi
  [[ "$curl_status" -eq 0 ]] || return 1
  local status="${response_without_timing##*$'\n'}"
  local body="${response_without_timing%$'\n'*}"
  [[ "$status" == "200" && "$body" == "$expected" ]]
}

live_ok=false
ready_ok=false
probe /livez '{"ok":true,"service":"address-atlas-sync"}' && live_ok=true
probe /healthz '{"ok":true,"service":"address-atlas-sync"}' && ready_ok=true

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
