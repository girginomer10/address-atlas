#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY="$SCRIPT_DIR/check-ruleset-governance.jq"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/address-atlas-ruleset-policy.XXXXXX")"
cleanup() { find "$TEST_ROOT" -depth -delete 2>/dev/null || true; }
trap cleanup EXIT

ALLOWLIST='{"main":[{"actor_id":100,"actor_type":"Team","bypass_mode":"pull_request"}],"releaseTags":[{"actor_id":200,"actor_type":"Integration","bypass_mode":"always"}]}'

cat > "$TEST_ROOT/valid.json" <<'JSON'
[
  {
    "target":"branch",
    "enforcement":"active",
    "conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},
    "bypass_actors":[{"actor_id":100,"actor_type":"Team","bypass_mode":"pull_request"}],
    "rules":[
      {"type":"deletion"}, {"type":"non_fast_forward"}, {"type":"required_linear_history"},
      {"type":"pull_request","parameters":{"dismiss_stale_reviews_on_push":true,"require_last_push_approval":true,"required_review_thread_resolution":true,"required_approving_review_count":1}},
      {"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":true,"do_not_enforce_on_create":false,"required_status_checks":[
        {"context":"Repository secret-artifact hygiene","integration_id":42},
        {"context":"Web and sync server","integration_id":42},
        {"context":"Native macOS package","integration_id":42},
        {"context":"Deployment configuration","integration_id":42}
      ]}}
    ]
  },
  {
    "target":"tag",
    "enforcement":"active",
    "conditions":{"ref_name":{"include":["refs/tags/v*"],"exclude":[]}},
    "bypass_actors":[{"actor_id":200,"actor_type":"Integration","bypass_mode":"always"}],
    "rules":[{"type":"creation"},{"type":"update"},{"type":"deletion"}]
  }
]
JSON

check() {
  jq -e --argjson ci_integration_id 42 \
    --argjson expected_bypass "$ALLOWLIST" -f "$POLICY" "$1" >/dev/null
}

check "$TEST_ROOT/valid.json"

jq '.[0] |= del(.bypass_actors)' "$TEST_ROOT/valid.json" > "$TEST_ROOT/missing.json"
if check "$TEST_ROOT/missing.json"; then
  echo 'ruleset policy accepted a missing bypass_actors field' >&2
  exit 1
fi

jq '.[0].bypass_actors += [{"actor_id":999,"actor_type":"Team","bypass_mode":"pull_request"}]' \
  "$TEST_ROOT/valid.json" > "$TEST_ROOT/unexpected.json"
if check "$TEST_ROOT/unexpected.json"; then
  echo 'ruleset policy accepted an unexpected bypass actor' >&2
  exit 1
fi

jq '.[0].bypass_actors[0].bypass_mode = "always"' \
  "$TEST_ROOT/valid.json" > "$TEST_ROOT/main-always.json"
always_allowlist='{"main":[{"actor_id":100,"actor_type":"Team","bypass_mode":"always"}],"releaseTags":[{"actor_id":200,"actor_type":"Integration","bypass_mode":"always"}]}'
if jq -e --argjson ci_integration_id 42 --argjson expected_bypass "$always_allowlist" \
    -f "$POLICY" "$TEST_ROOT/main-always.json" >/dev/null; then
  echo 'ruleset policy accepted always-mode bypass on main' >&2
  exit 1
fi

jq '.[0].bypass_actors[0].bypass_mode = "pull_request" | .[0].bypass_actors[0].actor_id = 101' \
  "$TEST_ROOT/valid.json" > "$TEST_ROOT/mismatch.json"
if check "$TEST_ROOT/mismatch.json"; then
  echo 'ruleset policy accepted a mismatched actor identity' >&2
  exit 1
fi

echo 'check-ruleset-governance-tests: 5/5 passed'
