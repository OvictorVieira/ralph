#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

project_root="$test_root/project"
fake_bin="$test_root/bin"
fake_home="$test_root/home"
codex_prompt="$test_root/CODEX.md"
amp_prompt="$test_root/AMP.md"
catalog_file="$test_root/models.json"
mkdir -p "$project_root" "$fake_bin" "$fake_home"

git -C "$project_root" init -q -b feature/startup-banner-test
git -C "$project_root" config user.name "Ralph Test"
git -C "$project_root" config user.email "ralph-test@example.com"

cat > "$project_root/prd.json" <<'JSON'
{
  "project": "Ralph startup banner regression",
  "branchName": "feature/startup-banner-test",
  "description": "Regression fixture",
  "userStories": []
}
JSON

cat > "$codex_prompt" <<'PROMPT'
Test driver. Do not run real inference.
<promise>COMPLETE</promise>
PROMPT
cp "$codex_prompt" "$amp_prompt"

cat > "$catalog_file" <<'JSON'
{
  "schemaVersion": 1,
  "providers": {
    "codex": {
      "cliBinary": "codex",
      "effortMechanism": "test",
      "models": {
        "known-model": {
          "label": "Known Model",
          "status": "active",
          "efforts": ["low", "high"],
          "defaultEffort": "high",
          "aliases": [],
          "successor": null,
          "minCliVersion": null,
          "source": null,
          "notes": null
        }
      }
    }
  }
}
JSON

mkdir -p "$fake_home/.codex"
cat > "$fake_home/.codex/config.toml" <<'TOML'
model = "known-model"
TOML

cat > "$fake_bin/codex" <<'FAKE_CODEX'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
  printf '%s\n' "${FAKE_CODEX_VERSION-codex-cli 1.2.3}"
  exit 0
fi

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

cat > "$fake_bin/amp" <<'FAKE_AMP'
#!/usr/bin/env bash
set -euo pipefail
printf '<promise>COMPLETE</promise>\n'
printf 'successful fake provider output: %0700d\n' 0
FAKE_AMP
chmod +x "$fake_bin/codex" "$fake_bin/amp"

run_ralph() {
  local prompt_file="$1"
  shift
  HOME="$fake_home" \
    PATH="$fake_bin:$PATH" \
    RALPH_CATALOG_FILE="$catalog_file" \
    RALPH_PROJECT_ROOT="$project_root" \
    RALPH_PROMPT_FILE="$prompt_file" \
    "$repo_root/ralph.sh" "$@" 2>&1
}

assert_contains() {
  local output="$1" expected="$2"
  [[ "$output" == *"$expected"* ]] || {
    printf 'missing expected banner text: %s\n%s\n' "$expected" "$output" >&2
    exit 1
  }
}

assert_not_contains() {
  local output="$1" unexpected="$2"
  [[ "$output" != *"$unexpected"* ]] || {
    printf 'unexpected banner text: %s\n%s\n' "$unexpected" "$output" >&2
    exit 1
  }
}

implicit_output="$(run_ralph "$codex_prompt" --tool codex --model known-model 1)"
assert_contains "$implicit_output" "Model:        known-model"
assert_contains "$implicit_output" "Model source: explicit"
assert_contains "$implicit_output" "Model status: active"
assert_contains "$implicit_output" "Effort:       model default (high)"
assert_contains "$implicit_output" "Effort source: provider-default"
assert_contains "$implicit_output" "Supported:    low high"
assert_contains "$implicit_output" "CLI version:  1.2.3"

configured_output="$(run_ralph "$codex_prompt" --tool codex 1)"
assert_contains "$configured_output" "Model:        codex default (known-model)"
assert_contains "$configured_output" "Model source: provider-config"
assert_contains "$configured_output" "Model status: active"
assert_contains "$configured_output" "Effort:       model default (high)"

explicit_output="$(run_ralph "$codex_prompt" --tool codex --model known-model --effort low 1)"
assert_contains "$explicit_output" "Effort:       low"
assert_contains "$explicit_output" "Effort source: explicit"

unknown_output="$(run_ralph "$codex_prompt" --tool codex --model manual-model 1)"
assert_contains "$unknown_output" "Model source: explicit"
assert_contains "$unknown_output" "Effort source: provider-default"
assert_contains "$unknown_output" "CLI version:  1.2.3"
assert_not_contains "$unknown_output" "Model status:"
assert_not_contains "$unknown_output" "Supported:"

versionless_output="$(FAKE_CODEX_VERSION= run_ralph "$codex_prompt" --tool codex --model known-model 1)"
assert_not_contains "$versionless_output" "CLI version:"

amp_output="$(run_ralph "$amp_prompt" --tool amp --model manual-model 1)"
assert_contains "$amp_output" "Model:        manual-model"
assert_not_contains "$amp_output" "Model source:"
assert_not_contains "$amp_output" "Model status:"
assert_not_contains "$amp_output" "Effort source:"
assert_not_contains "$amp_output" "Supported:"
assert_not_contains "$amp_output" "CLI version:"

echo "startup banner regression: pass"
