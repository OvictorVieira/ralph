#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

fake_bin="$test_root/bin"
fake_home="$test_root/home"
calls_file="$test_root/agy-calls"
mkdir -p "$fake_bin" "$fake_home"

cat > "$fake_bin/agy" <<'FAKE_AGY'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  --help)
    echo "Usage of agy:" >&2
    if [[ "${FAKE_AGY_MODE:-text}" != "text" ]]; then
      echo "  --output-format  Output format for print mode (text, json, stream-json)" >&2
    fi
    ;;
  --output-format)
    printf 'structured\n' >> "${FAKE_AGY_CALLS:?}"
    [[ "$*" == "--output-format json models" ]] || {
      printf 'unexpected structured invocation: %s\n' "$*" >&2
      exit 2
    }
    if [[ "${FAKE_AGY_MODE:-}" == "invalid-json" ]]; then
      echo "not json"
    else
      cat <<'JSON'
{"response":"response-noise","command":{"name":"models","data":{"models":[{"id":"vendor.model_exact-2","label":"Label Noise"},{"id":"alpha_model-1","label":"Another Label"}]}}}
JSON
    fi
    ;;
  models)
    printf 'text\n' >> "${FAKE_AGY_CALLS:?}"
    printf '%s\n' 'fallback-model Fallback Model'
    ;;
esac
FAKE_AGY
chmod +x "$fake_bin/agy"

run_ralph() {
  HOME="$fake_home" \
    PATH="$fake_bin:$PATH" \
    FAKE_AGY_CALLS="$calls_file" \
    RALPH_CATALOG_FILE="$test_root/missing-catalog.json" \
    "$repo_root/ralph.sh" --tool agy --list-models 2>&1
}

assert_contains() {
  local output="$1" expected="$2"
  [[ "$output" == *"$expected"* ]] || {
    printf 'missing expected output: %s\n%s\n' "$expected" "$output" >&2
    exit 1
  }
}

assert_not_contains() {
  local output="$1" unexpected="$2"
  [[ "$output" != *"$unexpected"* ]] || {
    printf 'unexpected output: %s\n%s\n' "$unexpected" "$output" >&2
    exit 1
  }
}

# A CLI advertising structured output must use its exact JSON model ids. Labels
# and unrelated response text must not leak into discovery.
: > "$calls_file"
structured_output="$(FAKE_AGY_MODE=structured run_ralph)"
assert_contains "$structured_output" "alpha_model-1 vendor.model_exact-2"
assert_not_contains "$structured_output" "Label"
assert_not_contains "$structured_output" "response-noise"
[[ "$(cat "$calls_file")" == "structured" ]] || {
  printf 'structured discovery unexpectedly used the text fallback\n%s\n' "$structured_output" >&2
  exit 1
}

# A CLI without the flag keeps the existing text parser path.
: > "$calls_file"
text_output="$(FAKE_AGY_MODE=text run_ralph)"
assert_contains "$text_output" "fallback-model"
[[ "$(cat "$calls_file")" == "text" ]] || {
  printf 'text-only CLI did not use fallback discovery\n%s\n' "$text_output" >&2
  exit 1
}

# Releases that advertise the flag but return unusable output also fail open to
# the legacy parser instead of producing an empty model list or crashing.
: > "$calls_file"
invalid_output="$(FAKE_AGY_MODE=invalid-json run_ralph)"
assert_contains "$invalid_output" "fallback-model"
[[ "$(cat "$calls_file")" == $'structured\ntext' ]] || {
  printf 'invalid structured output did not fall back to text\n%s\n' "$invalid_output" >&2
  exit 1
}

echo "AGY model discovery regression: pass"
