def exact_keys($expected):
  (keys_unsorted | sort) == ($expected | sort);

def valid_actor:
  type == "object"
  and exact_keys(["actor_id", "actor_type", "bypass_mode"])
  and (.actor_id | type == "number" and . > 0 and floor == .)
  and (.actor_type | type == "string" and test("^[A-Za-z][A-Za-z0-9]*$"))
  and (.bypass_mode == "pull_request" or .bypass_mode == "always");

def canonical_actors:
  sort_by(.actor_type, .actor_id, .bypass_mode);

def valid_expected_policy:
  type == "object"
  and exact_keys(["main", "releaseTags"])
  and (.main | type == "array" and all(.[]; valid_actor and .bypass_mode == "pull_request"))
  and (.releaseTags | type == "array" and all(.[]; valid_actor))
  and (.main | canonical_actors | unique | length) == (.main | length)
  and (.releaseTags | canonical_actors | unique | length) == (.releaseTags | length);

def exact_ref($target; $include):
  .target == $target
  and .enforcement == "active"
  and (.conditions | type == "object")
  and (.conditions.ref_name.include == [$include])
  and (.conditions.ref_name.exclude == []);

def has_rule($type):
  any(.rules[]?; .type == $type);

def exact_bypass($expected):
  (.bypass_actors | type == "array")
  and all(.bypass_actors[]; valid_actor)
  and ((.bypass_actors | canonical_actors) == ($expected | canonical_actors));

def strong_main($required_checks; $ci_integration_id; $expected_bypass):
  (exact_ref("branch"; "~DEFAULT_BRANCH") or exact_ref("branch"; "refs/heads/main"))
  and exact_bypass($expected_bypass)
  and has_rule("deletion")
  and has_rule("non_fast_forward")
  and has_rule("required_linear_history")
  and any(
    .rules[]?;
    .type == "pull_request"
    and .parameters.dismiss_stale_reviews_on_push == true
    and .parameters.require_last_push_approval == true
    and .parameters.required_review_thread_resolution == true
    and .parameters.required_approving_review_count >= 1
  )
  and any(
    .rules[]?;
    .type == "required_status_checks"
    and .parameters.strict_required_status_checks_policy == true
    and .parameters.do_not_enforce_on_create != true
    and (
      .parameters.required_status_checks as $configured
      | all(
          $required_checks[];
          . as $required
          | [$configured[]? | select(.context == $required)] as $matching
          | ($matching | length) == 1
            and $matching[0].integration_id == $ci_integration_id
        )
    )
  );

def strong_release_tags($expected_bypass):
  exact_ref("tag"; "refs/tags/v*")
  and exact_bypass($expected_bypass)
  and has_rule("creation")
  and has_rule("update")
  and has_rule("deletion");

[
  "Repository secret-artifact hygiene",
  "Web and sync server",
  "Native macOS package",
  "Deployment configuration"
] as $required_checks
| ($expected_bypass | select(valid_expected_policy)) as $policy
| [ .[] | select(.enforcement == "active" and .target == "branch") ] as $branch_rulesets
| [ .[] | select(.enforcement == "active" and .target == "tag") ] as $tag_rulesets
| ($branch_rulesets | length) == 1
  and ($tag_rulesets | length) == 1
  and ($branch_rulesets[0] | strong_main($required_checks; $ci_integration_id; $policy.main))
  and ($tag_rulesets[0] | strong_release_tags($policy.releaseTags))
