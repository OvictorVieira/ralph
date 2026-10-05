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
