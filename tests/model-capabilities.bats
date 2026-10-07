#!/usr/bin/env bats

load test_helper

setup() {
  setup_model_capability_test
}

@test "explicit Claude model and valid effort reach the provider as flags" {
  run_ralph claude --model known-claude --effort high 1

  assert_successful_run
  assert_argv_pair "$CALLS_DIR/claude.args" --model known-claude
  assert_argv_pair "$CALLS_DIR/claude.args" --effort high
}

@test "invalid effort for a known model fails before provider invocation" {
  run_ralph claude --model known-claude --effort medium 1

  [[ "$status" -eq 1 ]]
  assert_output_contains "Accepts: low high"
  [[ ! -e "$CALLS_DIR/claude.args" ]]
}

@test "retired model fails before provider invocation" {
  run_ralph codex --model retired-codex 1

  [[ "$status" -eq 1 ]]
  assert_output_contains "marked retired"
  assert_output_contains "ralph --tool codex --list-models"
  [[ ! -e "$CALLS_DIR/codex.args" ]]
}

@test "unknown model warns and passes through verbatim" {
  run_ralph claude --model manual-model 1

  assert_successful_run
  assert_output_contains "not in Ralph's 'claude' model catalog"
  assert_argv_pair "$CALLS_DIR/claude.args" --model manual-model
}

@test "catalog-known full model id never warns as unadvertised" {
  # The fake claude --help only quotes 'known-claude'/'runtime-claude' as
  # examples, same as the real CLI only quoting a few aliases. A full model
  # id the catalog already recognizes as active must still run clean and
  # forward both flags, instead of printing the generic "not advertised"
  # warning meant for ids the catalog has never heard of.
  run_ralph claude --model catalog-full-id-claude --effort high 1

  assert_successful_run
  assert_output_excludes "not in the model list 'claude' advertises"
  assert_argv_pair "$CALLS_DIR/claude.args" --model catalog-full-id-claude
  assert_argv_pair "$CALLS_DIR/claude.args" --effort high
}

@test "amp receives the selected model" {
  run_ralph amp --model known-amp-model 1

  assert_successful_run
  assert_argv_pair "$CALLS_DIR/amp.args" --model known-amp-model
}

@test "cursor bakes model and effort into one override argument" {
  run_ralph cursor --model known-cursor-model --effort high 1

  assert_successful_run
  assert_argv_pair "$CALLS_DIR/cursor-agent.args" --model 'known-cursor-model[effort=high]'
}

@test "opencode receives model flag and effort variant" {
  run_ralph opencode --model known/opencode-model --effort high 1

  assert_successful_run
  assert_argv_pair "$CALLS_DIR/opencode.args" --model known/opencode-model
  assert_argv_pair "$CALLS_DIR/opencode.args" --variant high
}

@test "implicit effort never adds Claude effort flags" {
  run_ralph claude --model known-claude 1

  assert_successful_run
  assert_no_argv_line "$CALLS_DIR/claude.args" "--effort"
  assert_no_argv_line "$CALLS_DIR/claude.args" "medium"
}

@test "Codex receives reasoning effort only when explicit" {
  run_ralph codex --model known-codex 1
  assert_successful_run
  assert_no_argv_line "$CALLS_DIR/codex.args" "model_reasoning_effort="

  rm "$CALLS_DIR/codex.args"
  run_ralph codex --model known-codex --effort high 1
  assert_successful_run
  assert_argv_pair "$CALLS_DIR/codex.args" -c 'model_reasoning_effort="high"'
}

@test "AGY always receives an explicit model and receives effort only when explicit" {
  run_ralph agy --model known-agy 1
  assert_successful_run
  assert_argv_pair "$CALLS_DIR/agy.args" --model known-agy
  assert_no_argv_line "$CALLS_DIR/agy.args" "--effort"

  rm "$CALLS_DIR/agy.args"
  run_ralph agy --model known-agy --effort low 1
  assert_successful_run
  assert_argv_pair "$CALLS_DIR/agy.args" --model known-agy
  assert_argv_pair "$CALLS_DIR/agy.args" --effort low
}

@test "tool-scoped model listing contains only Codex" {
  run_ralph codex --list-models

  assert_successful_run
  assert_output_contains "  codex    (installed)"
  assert_output_excludes "  claude   ("
  assert_output_excludes "  agy      ("
  assert_output_excludes "  amp      ("
}

@test "unscoped model listing includes every supported tool" {
  run env \
    HOME="$FAKE_HOME" \
    PATH="$FAKE_BIN:$PATH" \
    FAKE_PROVIDER_CALLS_DIR="$CALLS_DIR" \
    RALPH_CATALOG_FILE="$CATALOG_FILE" \
    "$REPO_ROOT/ralph.sh" --list-models

  assert_successful_run
  assert_output_contains "  amp      (installed)"
  assert_output_contains "  claude   (installed)"
  assert_output_contains "  codex    (installed)"
  assert_output_contains "  agy      (installed)"
  assert_output_contains "  cursor   (installed)"
  assert_output_contains "  opencode (installed)"
}

@test "runtime discovery failure falls back to catalog-only output" {
  export FAKE_DISCOVERY_FAIL=1
  run_ralph claude --list-models

  assert_successful_run
  assert_output_contains "known-claude"
  assert_output_contains "Catalog only: known-claude retired-claude"
}

@test "project roots containing spaces survive parsing and execution" {
  run_ralph codex --model known-codex --effort low 1

  assert_successful_run
  assert_output_contains "Project root: $PROJECT_ROOT"
  assert_argv_pair "$CALLS_DIR/codex.args" -C "$PROJECT_ROOT"
  assert_argv_pair "$CALLS_DIR/codex.args" --model known-codex
}

@test "non-zero provider exit halts before another iteration" {
  export FAKE_CODEX_MODE=generic-failure
  run_ralph codex 2

  [[ "$status" -eq 2 ]]
  assert_work_call_count codex 1
  assert_output_contains "provider 'codex' aborted iteration 1"
  assert_output_contains "provider exited with status 42"
  assert_output_contains "ERROR: fake codex rejected configured model"
  assert_output_excludes "Ralph Iteration 2"
}

@test "rejected configured Codex model retries once with cached same-variant model" {
  configure_codex_default
  write_codex_cache <<'JSON'
{"models":[
  {"slug":"gpt-6-astra","visibility":"list","supported_in_api":true,"priority":2},
  {"slug":"gpt-5.6-sol","visibility":"list","supported_in_api":true,"priority":5},
  {"slug":"gpt-5.6-terra","visibility":"list","supported_in_api":true,"priority":8}
]}
JSON
  export FAKE_CODEX_MODE=unsupported-default
  run_ralph codex --effort high 2

  assert_successful_run
  assert_work_call_count codex 2
  assert_output_contains "Codex model 'gpt-6-sol' is unavailable for this account"
  assert_output_contains "equivalent model 'gpt-5.6-sol'"
  assert_output_excludes "Ralph Iteration 2"
  assert_argv_pair "$CALLS_DIR/codex.args" --model gpt-5.6-sol
  assert_argv_pair "$CALLS_DIR/codex.args" -c 'model_reasoning_effort="high"'
}

@test "explicit Codex model rejection never triggers fallback" {
  configure_codex_default
  write_codex_cache <<'JSON'
{"models":[{"slug":"gpt-5.6-sol","visibility":"list","supported_in_api":true,"priority":1}]}
JSON
  export FAKE_CODEX_MODE=unsupported-default
  run_ralph codex --model gpt-6-sol --effort high 2

  [[ "$status" -eq 2 ]]
  assert_work_call_count codex 1
  assert_output_excludes "Retrying once"
  assert_output_excludes "Ralph Iteration 2"
}

@test "quota failure keeps its specific diagnosis and never triggers fallback" {
  configure_codex_default
  write_codex_cache <<'JSON'
{"models":[{"slug":"gpt-5.6-sol","visibility":"list","supported_in_api":true,"priority":1}]}
JSON
  export FAKE_CODEX_MODE=quota
  run_ralph codex --effort high 2

  [[ "$status" -eq 2 ]]
  assert_work_call_count codex 1
  assert_output_contains "quota/auth message in stream"
  assert_output_contains "provider exited with status 1"
  assert_output_excludes "Retrying once"
  assert_output_excludes "Ralph Iteration 2"
}

@test "missing Codex cache may use active same-variant catalog fallback" {
  configure_codex_default
  export FAKE_CODEX_MODE=unsupported-default
  run_ralph codex --effort high 2

  assert_successful_run
  assert_work_call_count codex 2
  assert_output_contains "equivalent model 'gpt-5.6-sol'"
  assert_argv_pair "$CALLS_DIR/codex.args" --model gpt-5.6-sol
}

@test "valid cache without same variant does not promote catalog-only fallback" {
  configure_codex_default
  write_codex_cache <<'JSON'
{"models":[{"slug":"gpt-6-astra","visibility":"list","supported_in_api":true,"priority":1}]}
JSON
  export FAKE_CODEX_MODE=unsupported-default
  run_ralph codex --effort high 2

  [[ "$status" -eq 2 ]]
  assert_work_call_count codex 1
  assert_output_excludes "Retrying once"
  assert_output_excludes "Ralph Iteration 2"
}

@test "failed Codex fallback halts after its single retry" {
  configure_codex_default
  write_codex_cache <<'JSON'
{"models":[{"slug":"gpt-5.6-sol","visibility":"list","supported_in_api":true,"priority":1}]}
JSON
  export FAKE_CODEX_MODE=fallback-failure
  run_ralph codex --effort high 2

  [[ "$status" -eq 2 ]]
  assert_work_call_count codex 2
  assert_output_contains "provider exited with status 44"
  assert_output_contains "ERROR: fallback model failed after selection"
  assert_output_excludes "Ralph Iteration 2"
}
