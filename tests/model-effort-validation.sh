#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

project_root="$test_root/project"
fake_bin="$test_root/bin"
fake_home="$test_root/home"
configured_home="$test_root/configured-home"
prompt_file="$test_root/CODEX.md"
catalog_file="$test_root/models.json"
calls_file="$test_root/codex-calls"
mkdir -p "$project_root" "$fake_bin" "$fake_home" "$configured_home/.codex"

git -C "$project_root" init -q -b feature/model-validation-test
git -C "$project_root" config user.name "Ralph Test"
git -C "$project_root" config user.email "ralph-test@example.com"

cat > "$project_root/prd.json" <<'JSON'
{
  "project": "Ralph model validation regression",
  "branchName": "feature/model-validation-test",
  "description": "Regression fixture",
  "userStories": []
}
JSON

cat > "$prompt_file" <<'PROMPT'
Test driver. Do not run real inference.
<promise>COMPLETE</promise>
PROMPT

cat > "$catalog_file" <<'JSON'
{
  "schemaVersion": 1,
  "providers": {
    "codex": {
      "cliBinary": "codex",
      "effortMechanism": "test",
      "models": {
        "active-model": {
          "label": "Active Model",
          "status": "active",
          "efforts": ["low", "medium"],
          "defaultEffort": null,
          "aliases": [],
          "successor": null,
          "minCliVersion": null,
          "source": null,
          "notes": null
        },
        "retired-model": {
          "label": "Retired Model",
          "status": "retired",
          "efforts": ["low"],
          "defaultEffort": null,
          "aliases": [],
          "successor": "active-model",
          "minCliVersion": null,
          "source": null,
          "notes": null
        },
        "superseded-model": {
          "label": "Superseded Model",
          "status": "superseded",
          "efforts": ["low"],
          "defaultEffort": null,
          "aliases": [],
          "successor": "active-model",
          "minCliVersion": null,
          "source": null,
          "notes": null
        },
        "deprecated-model": {
          "label": "Deprecated Model",
          "status": "deprecated",
          "efforts": ["low"],
          "defaultEffort": null,
          "aliases": [],
          "successor": "active-model",
          "minCliVersion": null,
          "source": null,
          "notes": null
        }
      }
    }
  }
}
JSON

cat > "$configured_home/.codex/config.toml" <<'TOML'
model = "retired-model"
TOML

cat > "$fake_bin/codex" <<'FAKE_CODEX'
#!/usr/bin/env bash
set -euo pipefail
: "${FAKE_CODEX_CALLS:?}"
printf '%s\n' "$*" >> "$FAKE_CODEX_CALLS"

last_message=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      last_message="$2"
      shift 2
      ;;
    *) shift ;;
  esac
done

printf '<promise>COMPLETE</promise>\n' > "$last_message"
printf 'successful fake provider output: %0700d\n' 0
FAKE_CODEX
chmod +x "$fake_bin/codex"

run_ralph() {
  local home_dir="$1"
  shift
  HOME="$home_dir" \
    PATH="$fake_bin:$PATH" \
    FAKE_CODEX_CALLS="$calls_file" \
    RALPH_CATALOG_FILE="$catalog_file" \
    RALPH_PROJECT_ROOT="$project_root" \
    RALPH_PROMPT_FILE="$prompt_file" \
    "$repo_root/ralph.sh" --tool codex "$@" 2>&1
}

assert_fail_fast() {
  local expected="$1"
  shift
  : > "$calls_file"
  set +e
  local output
  output="$(run_ralph "$@")"
  local status=$?
  set -e
  [[ "$status" -eq 1 ]] || {
    printf 'expected exit 1, got %s\n%s\n' "$status" "$output" >&2
    exit 1
  }
  [[ ! -s "$calls_file" ]] || {
    printf 'provider was invoked before fail-fast validation\n%s\n' "$output" >&2
    exit 1
  }
  [[ "$output" == *"$expected"* ]] || {
    printf 'missing expected diagnostic: %s\n%s\n' "$expected" "$output" >&2
    exit 1
  }
}

assert_success() {
  local expected="$1"
  shift
  : > "$calls_file"
  local output
  output="$(run_ralph "$@")"
  [[ "$(wc -l < "$calls_file" | tr -d ' ')" -eq 1 ]] || {
    printf 'expected exactly one provider invocation\n%s\n' "$output" >&2
    exit 1
  }
  [[ "$output" == *"$expected"* ]] || {
    printf 'missing expected diagnostic: %s\n%s\n' "$expected" "$output" >&2
    exit 1
  }
}

assert_fail_fast "Accepts: low medium" "$fake_home" --model active-model --effort high 1
assert_fail_fast "marked retired" "$fake_home" --model retired-model 1
assert_fail_fast "marked retired" "$configured_home" 1

assert_success "not in Ralph's 'codex' model catalog" "$fake_home" --model manual-model 1
[[ "$(cat "$calls_file")" == *"--model manual-model"* ]] || {
  printf 'unknown model was not passed through verbatim\n%s\n' "$(cat "$calls_file")" >&2
  exit 1
}

assert_success "Notice: model 'superseded-model' is superseded" "$fake_home" --model superseded-model 1
assert_success "WARNING: model 'deprecated-model' is DEPRECATED" "$fake_home" --model deprecated-model 1

echo "model/effort validation regression: pass"
