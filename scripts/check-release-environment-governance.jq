def exact_keys($keys):
  type == "object" and (keys == ($keys | sort));

($expected | length == 1) and
($expected[0] as $policy |
  ($policy | exact_keys([
    "administratorsCanBypass",
    "environment",
    "reviewers",
    "schemaVersion"
  ])) and
  $policy.schemaVersion == 1 and
  $policy.environment == "release" and
  $policy.administratorsCanBypass == false and
  ($policy.reviewers | type == "array" and length > 0) and
  all(
    $policy.reviewers[];
    exact_keys(["id", "type"]) and
    (.type == "User" or .type == "Team") and
    (.id | type == "number" and . > 0 and floor == .)
  ) and
  ([ $policy.reviewers[] | [.type, .id] ] | unique | length)
    == ($policy.reviewers | length) and

  .name == $policy.environment and
  .can_admins_bypass == $policy.administratorsCanBypass and
  (.deployment_branch_policy | type == "object") and
  .deployment_branch_policy.protected_branches == false and
  .deployment_branch_policy.custom_branch_policies == true and
  (.protection_rules | type == "array") and
  ([ .protection_rules[] | select(.type == "required_reviewers") ]) as $rules |
  ($rules | length) == 1 and
  $rules[0].prevent_self_review == true and
  ($rules[0].reviewers | type == "array") and
  all(
    $rules[0].reviewers[];
    (.type == "User" or .type == "Team") and
    (.reviewer | type == "object") and
    (.reviewer.id | type == "number" and . > 0 and floor == .)
  ) and
  ([
    $rules[0].reviewers[]
    | { type: .type, id: .reviewer.id }
  ] | sort_by(.type, .id)) == ($policy.reviewers | sort_by(.type, .id))
)
