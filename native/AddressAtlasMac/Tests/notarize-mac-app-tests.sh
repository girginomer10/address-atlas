#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$ROOT/notarize-mac-app.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/address-atlas-notary-tests.XXXXXX")"
passed=0
failed=0

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'FAIL %s\n' "$1" >&2
  failed=$((failed + 1))
}

pass() {
  printf 'PASS %s\n' "$1"
  passed=$((passed + 1))
}

assert_status() {
  local actual="$1" expected="$2" message="$3"
  [[ "$actual" -eq "$expected" ]] || {
    fail "$message (expected $expected, received $actual)"
    return 1
  }
}

assert_contains() {
  local path="$1" expected="$2" message="$3"
  grep -Fq -- "$expected" "$path" || {
    fail "$message"
    return 1
  }
}

assert_not_contains() {
  local path="$1" unexpected="$2" message="$3"
  if grep -Fq -- "$unexpected" "$path"; then
    fail "$message"
    return 1
  fi
}

new_case() {
  CASE_DIR="$(mktemp -d "$TEST_ROOT/case.XXXXXX")"
  mkdir -p "$CASE_DIR/bin" "$CASE_DIR/tmp"
  cp "$TARGET" "$CASE_DIR/notarize-mac-app.sh"
  chmod 0700 "$CASE_DIR/notarize-mac-app.sh"

  cat > "$CASE_DIR/build-dmg.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$root/dist/Address Atlas.app/Contents/MacOS"
printf 'app fixture\n' > "$root/dist/Address Atlas.app/Contents/MacOS/Address Atlas"
chmod 0700 "$root/dist/Address Atlas.app/Contents/MacOS/Address Atlas"
printf 'signed dmg fixture\n' > "$root/dist/Address Atlas.dmg"
printf 'built\n' >> "$root/events.log"
EOF

  cat > "$CASE_DIR/bin/xcrun" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'xcrun' >> "$CASE_DIR/events.log"
printf ' <%s>' "$@" >> "$CASE_DIR/events.log"
printf '\n' >> "$CASE_DIR/events.log"
if [[ "${1:-}" == "lipo" && "${2:-}" == "-archs" ]]; then
  printf '%s\n' "${FAKE_APP_ARCHS:-arm64 x86_64}"
  exit 0
fi
if [[ "${1:-}" == "notarytool" && "${2:-}" == "submit" ]]; then
  printf '%s\n' "${FAKE_SUBMISSION_JSON:-{\"id\":\"12345678-1234-1234-1234-123456789abc\",\"status\":\"Accepted\"}}"
  exit "${FAKE_SUBMIT_STATUS:-0}"
fi
if [[ "${1:-}" == "notarytool" && "${2:-}" == "log" ]]; then
  printf '%s\n' "${FAKE_LOG_JSON:-{\"status\":\"Accepted\",\"issues\":[]}}"
fi
EOF

  for tool in codesign spctl hdiutil; do
    cat > "$CASE_DIR/bin/$tool" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s' "$(basename "$0")" >> "$CASE_DIR/events.log"
printf ' <%s>' "$@" >> "$CASE_DIR/events.log"
printf '\n' >> "$CASE_DIR/events.log"
EOF
  done

  cat > "$CASE_DIR/bin/plutil" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
field="${2:-}"
path="${@: -1}"
case "$field" in
  id) sed -nE 's/.*"id"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$path" ;;
  status) sed -nE 's/.*"status"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$path" ;;
  *) exit 1 ;;
esac
EOF
  chmod 0700 "$CASE_DIR/build-dmg.sh" "$CASE_DIR/bin/"*

  KEY_PATH="$CASE_DIR/AuthKey_TESTKEY123.p8"
  printf '%s\n' 'PRIVATE_NOTARY_KEY_MATERIAL_TEST_ONLY' > "$KEY_PATH"
  chmod 0600 "$KEY_PATH"
  : > "$CASE_DIR/events.log"
}

run_notarize() {
  local profile="${1-}" key_path="${2-$KEY_PATH}" key_id="${3-TESTKEY123}"
  local issuer="${4-12345678-1234-1234-1234-123456789abc}" timeout="${5-}"
  set +e
  env -i \
    PATH="$CASE_DIR/bin:/usr/bin:/bin" \
    TMPDIR="$CASE_DIR/tmp" \
    CASE_DIR="$CASE_DIR" \
    FAKE_SUBMISSION_JSON="${FAKE_SUBMISSION_JSON:-}" \
    FAKE_SUBMIT_STATUS="${FAKE_SUBMIT_STATUS:-0}" \
    FAKE_LOG_JSON="${FAKE_LOG_JSON:-}" \
    FAKE_APP_ARCHS="${FAKE_APP_ARCHS:-arm64 x86_64}" \
    ADDRESS_ATLAS_CODESIGN_IDENTITY='Developer ID Application: Test (TEAMID1234)' \
    ADDRESS_ATLAS_NOTARY_PROFILE="$profile" \
    ADDRESS_ATLAS_NOTARY_KEY_PATH="$key_path" \
    ADDRESS_ATLAS_NOTARY_KEY_ID="$key_id" \
    ADDRESS_ATLAS_NOTARY_ISSUER_ID="$issuer" \
    ADDRESS_ATLAS_NOTARY_TIMEOUT="$timeout" \
    XCRUN_BIN="$CASE_DIR/bin/xcrun" \
    CODESIGN_BIN="$CASE_DIR/bin/codesign" \
    SPCTL_BIN="$CASE_DIR/bin/spctl" \
    HDIUTIL_BIN="$CASE_DIR/bin/hdiutil" \
    PLUTIL_BIN="$CASE_DIR/bin/plutil" \
    BUILD_DMG_SCRIPT="$CASE_DIR/build-dmg.sh" \
    "$CASE_DIR/notarize-mac-app.sh" > "$CASE_DIR/stdout" 2> "$CASE_DIR/stderr"
  RUN_STATUS=$?
  set -e
}

test_direct_credentials() {
  new_case
  run_notarize
  assert_status "$RUN_STATUS" 0 'direct credentials exit status' || return
  assert_contains "$CASE_DIR/events.log" '<notarytool> <submit>' 'direct submit missing' || return
  assert_contains "$CASE_DIR/events.log" "<--key> <$KEY_PATH> <--key-id> <TESTKEY123>" 'direct credential arguments missing' || return
  assert_contains "$CASE_DIR/events.log" '<--wait> <--timeout> <30m>' 'finite default notary timeout missing' || return
  assert_contains "$CASE_DIR/events.log" '<stapler> <staple>' 'accepted artifact was not stapled' || return
  assert_contains "$CASE_DIR/events.log" 'hdiutil <verify>' 'DMG verification missing' || return
  assert_contains "$CASE_DIR/stdout" 'Notarized and stapled' 'success output missing' || return
  assert_not_contains "$CASE_DIR/stdout" 'PRIVATE_NOTARY_KEY' 'key material leaked to stdout' || return
  pass 'direct App Store Connect credentials'
}

test_keychain_profile() {
  new_case
  run_notarize 'address-atlas-notary' '' '' ''
  assert_status "$RUN_STATUS" 0 'Keychain profile exit status' || return
  assert_contains "$CASE_DIR/events.log" '<--keychain-profile> <address-atlas-notary>' 'profile argument missing' || return
  assert_not_contains "$CASE_DIR/events.log" '<--key-id>' 'direct key arguments leaked into profile mode' || return
  pass 'Keychain profile credentials'
}

test_custom_timeout() {
  new_case
  run_notarize '' "$KEY_PATH" 'TESTKEY123' \
    '12345678-1234-1234-1234-123456789abc' '17m'
  assert_status "$RUN_STATUS" 0 'custom timeout exit status' || return
  assert_contains "$CASE_DIR/events.log" '<--wait> <--timeout> <17m>' \
    'custom notary timeout missing' || return
  pass 'custom finite timeout'
}

test_invalid_timeouts_rejected() {
  local timeout
  for timeout in 0 01m 1.5m 59s 2h 3601s 30M infinite; do
    new_case
    run_notarize '' "$KEY_PATH" 'TESTKEY123' \
      '12345678-1234-1234-1234-123456789abc' "$timeout"
    assert_status "$RUN_STATUS" 64 "invalid timeout ${timeout} exit status" || return
    assert_contains "$CASE_DIR/stderr" 'ADDRESS_ATLAS_NOTARY_TIMEOUT' \
      "invalid timeout ${timeout} error missing" || return
    assert_not_contains "$CASE_DIR/events.log" 'built' \
      "invalid timeout ${timeout} reached artifact build" || return
  done
  pass 'invalid timeout rejection'
}

test_timeout_exit_is_fail_closed() {
  new_case
  FAKE_SUBMIT_STATUS=124
  run_notarize
  unset FAKE_SUBMIT_STATUS
  assert_status "$RUN_STATUS" 124 'notary timeout exit status' || return
  assert_contains "$CASE_DIR/stderr" 'notarization was not accepted' \
    'notary timeout rejection message missing' || return
  assert_not_contains "$CASE_DIR/events.log" '<stapler> <staple>' \
    'timed-out artifact was stapled' || return
  pass 'notary timeout failure handling'
}

test_mixed_credentials_rejected() {
  new_case
  run_notarize 'address-atlas-notary'
  assert_status "$RUN_STATUS" 64 'mixed credentials exit status' || return
  assert_contains "$CASE_DIR/stderr" 'never both' 'mixed credential error missing' || return
  assert_not_contains "$CASE_DIR/events.log" 'built' 'mixed credentials reached artifact build' || return
  pass 'mixed credential rejection'
}

test_incomplete_credentials_rejected() {
  new_case
  run_notarize '' "$KEY_PATH" '' '12345678-1234-1234-1234-123456789abc'
  assert_status "$RUN_STATUS" 64 'incomplete credentials exit status' || return
  assert_contains "$CASE_DIR/stderr" 'set ADDRESS_ATLAS_NOTARY_KEY_PATH' 'incomplete credential error missing' || return
  assert_not_contains "$CASE_DIR/events.log" 'built' 'incomplete credentials reached artifact build' || return
  pass 'incomplete credential rejection'
}

test_key_permissions_rejected() {
  new_case
  chmod 0644 "$KEY_PATH"
  run_notarize
  assert_status "$RUN_STATUS" 66 'permissive key exit status' || return
  assert_contains "$CASE_DIR/stderr" 'must not be accessible' 'key permission error missing' || return
  assert_not_contains "$CASE_DIR/events.log" 'built' 'permissive key reached artifact build' || return
  pass 'API key permission rejection'
}

test_rejected_submission() {
  new_case
  FAKE_SUBMISSION_JSON='{"id":"12345678-1234-1234-1234-123456789abc","status":"Invalid"}'
  FAKE_LOG_JSON='{"status":"Invalid","issues":[{"message":"signature invalid"}]}'
  run_notarize
  unset FAKE_SUBMISSION_JSON FAKE_LOG_JSON
  assert_status "$RUN_STATUS" 1 'rejected notarization exit status' || return
  assert_contains "$CASE_DIR/stderr" 'status Invalid' 'rejected status missing' || return
  assert_contains "$CASE_DIR/stderr" 'signature invalid' 'bounded Apple diagnostic log missing' || return
  assert_not_contains "$CASE_DIR/events.log" '<stapler> <staple>' 'rejected artifact was stapled' || return
  assert_not_contains "$CASE_DIR/stderr" 'PRIVATE_NOTARY_KEY' 'key material leaked on failure' || return
  pass 'rejected notarization handling'
}

test_non_universal_app_is_rejected_before_submission() {
  local invalid_arches
  for invalid_arches in 'arm64' 'x86_64' 'arm64 arm64' 'arm64 x86_64 ppc'; do
    new_case
    FAKE_APP_ARCHS="$invalid_arches"
    run_notarize
    unset FAKE_APP_ARCHS
    assert_status "$RUN_STATUS" 65 "invalid architectures '$invalid_arches' exit status" \
      || return
    assert_contains "$CASE_DIR/stderr" 'exact arm64 + x86_64 universal' \
      "invalid architectures '$invalid_arches' rejection message missing" || return
    assert_not_contains "$CASE_DIR/events.log" '<notarytool> <submit>' \
      "invalid architectures '$invalid_arches' reached notarization submission" || return
  done
  pass 'non-universal app rejection'
}

test_universal_app_accepts_reverse_lipo_order() {
  new_case
  FAKE_APP_ARCHS='x86_64 arm64'
  run_notarize
  unset FAKE_APP_ARCHS
  assert_status "$RUN_STATUS" 0 'reverse universal architecture order exit status' || return
  assert_contains "$CASE_DIR/events.log" '<notarytool> <submit>' \
    'reverse universal architecture order did not reach submission' || return
  pass 'universal architecture order independence'
}

run_test() {
  "$1" || true
}

run_test test_direct_credentials
run_test test_keychain_profile
run_test test_custom_timeout
run_test test_invalid_timeouts_rejected
run_test test_timeout_exit_is_fail_closed
run_test test_mixed_credentials_rejected
run_test test_incomplete_credentials_rejected
run_test test_key_permissions_rejected
run_test test_rejected_submission
run_test test_non_universal_app_is_rejected_before_submission
run_test test_universal_app_accepts_reverse_lipo_order

printf '%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
