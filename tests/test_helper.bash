setup_model_capability_test() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TEST_ROOT="$BATS_TEST_TMPDIR/ralph fixture"
  PROJECT_ROOT="$TEST_ROOT/project with spaces"
  FAKE_BIN="$TEST_ROOT/fake bin"
  FAKE_HOME="$TEST_ROOT/home"
  CALLS_DIR="$TEST_ROOT/provider calls"
  PROMPT_FILE="$TEST_ROOT/CODEX.md"
  CATALOG_FILE="$REPO_ROOT/tests/fixtures/model-capabilities.json"

  mkdir -p "$PROJECT_ROOT" "$FAKE_BIN" "$FAKE_HOME" "$CALLS_DIR"

  local provider
  for provider in amp claude codex agy cursor-agent opencode; do
    cp "$REPO_ROOT/tests/fixtures/fake-provider" "$FAKE_BIN/$provider"
    chmod +x "$FAKE_BIN/$provider"
  done

  git -C "$PROJECT_ROOT" init -q -b feature/model-capability-test
  git -C "$PROJECT_ROOT" config user.name "Ralph Test"
  git -C "$PROJECT_ROOT" config user.email "ralph-test@example.com"

  cp "$REPO_ROOT/tests/fixtures/project-prd.json" "$PROJECT_ROOT/prd.json"
  cp "$REPO_ROOT/tests/fixtures/test-prompt.md" "$PROMPT_FILE"
}

run_ralph() {
  local tool="$1"
  shift
  run env \
    HOME="$FAKE_HOME" \
    PATH="$FAKE_BIN:$PATH" \
    FAKE_PROVIDER_CALLS_DIR="$CALLS_DIR" \
    FAKE_DISCOVERY_FAIL="${FAKE_DISCOVERY_FAIL:-0}" \
    RALPH_CATALOG_FILE="$CATALOG_FILE" \
    RALPH_PROJECT_ROOT="$PROJECT_ROOT" \
    RALPH_PROMPT_FILE="$PROMPT_FILE" \
    "$REPO_ROOT/ralph.sh" --tool "$tool" "$@"
}

assert_successful_run() {
  if [[ "$status" -ne 0 ]]; then
    printf 'expected success, got status %s\n%s\n' "$status" "$output" >&2
    return 1
  fi
}

assert_output_contains() {
  local expected="$1"
  if [[ "$output" != *"$expected"* ]]; then
    printf 'missing expected output: %s\n%s\n' "$expected" "$output" >&2
    return 1
  fi
}

assert_output_excludes() {
  local unexpected="$1"
  if [[ "$output" == *"$unexpected"* ]]; then
    printf 'unexpected output: %s\n%s\n' "$unexpected" "$output" >&2
    return 1
  fi
}

assert_argv_pair() {
  local file="$1" flag="$2" value="$3"
  if ! awk -v flag="$flag" -v value="$value" \
    '$0 == flag { getline; if ($0 == value) found=1 } END { exit !found }' "$file"; then
    printf 'missing argv pair %s %s in %s\n' "$flag" "$value" "$file" >&2
    sed -n '1,160p' "$file" >&2
    return 1
  fi
}

assert_no_argv_line() {
  local file="$1" unexpected="$2"
  if grep -Fq -- "$unexpected" "$file"; then
    printf 'unexpected argv content %s in %s\n' "$unexpected" "$file" >&2
    sed -n '1,160p' "$file" >&2
    return 1
  fi
}
