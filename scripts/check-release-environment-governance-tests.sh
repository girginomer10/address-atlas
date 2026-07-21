#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHECKER="${SCRIPT_DIR}/check-release-environment-governance.jq"
POLICY="${ROOT_DIR}/.github/release-environment-policy.json"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/address-atlas-release-environment.XXXXXX")"
cleanup() {
  find "$TEST_ROOT" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT

cat > "$TEST_ROOT/valid.json" <<'JSON'
{
  "name": "release",
  "can_admins_bypass": false,
  "deployment_branch_policy": {
    "protected_branches": false,
    "custom_branch_policies": true
  },
  "protection_rules": [
    {
      "id": 11,
      "type": "required_reviewers",
      "prevent_self_review": true,
      "reviewers": [
        {
          "type": "User",
          "reviewer": { "id": 67194558, "login": "girginomer10" }
        }
      ]
    },
    { "id": 12, "type": "branch_policy" }
  ]
}
JSON

accepts() {
  local actual="$1" policy="${2:-$POLICY}"
  jq -e --slurpfile expected "$policy" -f "$CHECKER" "$actual" >/dev/null
}

rejects() {
  local actual="$1" policy="${2:-$POLICY}"
  if accepts "$actual" "$policy"; then
    echo "release-environment checker accepted an unsafe fixture: $(basename "$actual")" >&2
    exit 1
  fi
}

accepts "$TEST_ROOT/valid.json"

jq '.can_admins_bypass = true' "$TEST_ROOT/valid.json" > "$TEST_ROOT/admin-bypass.json"
rejects "$TEST_ROOT/admin-bypass.json"
jq 'del(.can_admins_bypass)' "$TEST_ROOT/valid.json" > "$TEST_ROOT/admin-missing.json"
rejects "$TEST_ROOT/admin-missing.json"
jq '(.protection_rules[] | select(.type == "required_reviewers") | .reviewers[0].reviewer.id) = 9' \
  "$TEST_ROOT/valid.json" > "$TEST_ROOT/reviewer-mismatch.json"
rejects "$TEST_ROOT/reviewer-mismatch.json"
jq '(.protection_rules[] | select(.type == "required_reviewers") | .reviewers) += [{"type":"Team","reviewer":{"id":7}}]' \
  "$TEST_ROOT/valid.json" > "$TEST_ROOT/extra-reviewer.json"
rejects "$TEST_ROOT/extra-reviewer.json"
jq '(.protection_rules[] | select(.type == "required_reviewers") | .reviewers) += [{}]' \
  "$TEST_ROOT/valid.json" > "$TEST_ROOT/malformed-reviewer.json"
rejects "$TEST_ROOT/malformed-reviewer.json"
jq '(.protection_rules[] | select(.type == "required_reviewers") | .prevent_self_review) = false' \
  "$TEST_ROOT/valid.json" > "$TEST_ROOT/self-review.json"
rejects "$TEST_ROOT/self-review.json"
jq '.protection_rules += [.protection_rules[0]]' "$TEST_ROOT/valid.json" \
  > "$TEST_ROOT/duplicate-rule.json"
rejects "$TEST_ROOT/duplicate-rule.json"
jq '.deployment_branch_policy.custom_branch_policies = false' "$TEST_ROOT/valid.json" \
  > "$TEST_ROOT/broad-branch-policy.json"
rejects "$TEST_ROOT/broad-branch-policy.json"
jq '.reviewers += [.reviewers[0]]' "$POLICY" > "$TEST_ROOT/duplicate-policy-reviewer.json"
rejects "$TEST_ROOT/valid.json" "$TEST_ROOT/duplicate-policy-reviewer.json"

echo 'check-release-environment-governance-tests: 10/10 passed'
