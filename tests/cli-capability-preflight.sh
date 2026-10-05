#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

project_root="$test_root/project"
fake_bin="$test_root/bin"
fake_home="$test_root/home"
prompt_file="$test_root/CLAUDE.md"
catalog_file="$test_root/models.json"
calls_file="$test_root/provider-calls"
mkdir -p "$project_root" "$fake_bin" "$fake_home"

git -C "$project_root" init -q -b feature/cli-preflight-test
git -C "$project_root" config user.name "Ralph Test"
git -C "$project_root" config user.email "ralph-test@example.com"

cat > "$project_root/prd.json" <<'JSON'
{
  "project": "Ralph CLI preflight regression",
  "branchName": "feature/cli-preflight-test",
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
    "claude": {
      "cliBinary": "claude",
      "effortMechanism": "test",
      "models": {
        "future-claude": {
          "label": "Future Claude",
          "status": "active",
          "efforts": ["high"],
          "defaultEffort": null,
          "aliases": [],
          "successor": null,
          "minCliVersion": "2.5.0",
          "source": null,
          "notes": null
        }
      }
    },
    "codex": {
      "cliBinary": "codex",
      "effortMechanism": "test",
      "models": {
        "future-codex": {
          "label": "Future Codex",
          "status": "active",
          "efforts": ["high"],
          "defaultEffort": null,
          "aliases": [],
          "successor": null,
          "minCliVersion": "1.2.0",
          "source": null,
          "notes": null
        }
      }
    }
  }
}
JSON

cat > "$fake_bin/claude" <<'FAKE_CLAUDE'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  --help)
    echo "Usage: claude --model <model>"
    if [[ "${FAKE_CLAUDE_EFFORT_SUPPORT:-0}" == "1" ]]; then
      echo "  --effort <level>"
    fi
    exit 0
    ;;
  --version)
    [[ -n "${FAKE_CLAUDE_VERSION:-}" ]] && echo "$FAKE_CLAUDE_VERSION"
    exit 0
    ;;
esac
: "${FAKE_PROVIDER_CALLS:?}"
printf 'claude\n' >> "$FAKE_PROVIDER_CALLS"
printf '<promise>COMPLETE</promise>\n'
printf 'successful fake provider output: %0700d\n' 0
FAKE_CLAUDE

cat > "$fake_bin/codex" <<'FAKE_CODEX'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
  [[ -n "${FAKE_CODEX_VERSION:-}" ]] && echo "$FAKE_CODEX_VERSION"
  exit 0
fi
: "${FAKE_PROVIDER_CALLS:?}"
printf 'codex\n' >> "$FAKE_PROVIDER_CALLS"
exit 99
FAKE_CODEX
chmod +x "$fake_bin/claude" "$fake_bin/codex"

run_ralph() {
  HOME="$fake_home" \
    PATH="$fake_bin:$PATH" \
    FAKE_PROVIDER_CALLS="$calls_file" \
    RALPH_CATALOG_FILE="$catalog_file" \
    RALPH_PROJECT_ROOT="$project_root" \
    RALPH_PROMPT_FILE="$prompt_file" \
    "$repo_root/ralph.sh" "$@" 2>&1
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
    printf 'provider work invocation occurred before fail-fast\n%s\n' "$output" >&2
    exit 1
  }
  [[ "$output" == *"$expected"* ]] || {
    printf 'missing expected diagnostic: %s\n%s\n' "$expected" "$output" >&2
    exit 1
  }
}

FAKE_CLAUDE_EFFORT_SUPPORT=0 FAKE_CLAUDE_VERSION="2.6.0 (Claude Code)" \
  assert_fail_fast "does not advertise --effort support" \
  --tool claude --model future-claude --effort high 1

FAKE_CLAUDE_EFFORT_SUPPORT=1 FAKE_CLAUDE_VERSION="2.4.9 (Claude Code)" \
  assert_fail_fast "requires claude CLI 2.5.0 or newer" \
  --tool claude --model future-claude 1

FAKE_CODEX_VERSION="codex-cli 1.1.9" \
  assert_fail_fast "requires codex CLI 1.2.0 or newer" \
  --tool codex --model future-codex 1

# An undetectable version must skip the minimum-version gate without a false
# failure. The fake provider emits Ralph's completion sentinel when invoked.
: > "$calls_file"
output="$(
  FAKE_CLAUDE_EFFORT_SUPPORT=1 FAKE_CLAUDE_VERSION="" \
    run_ralph --tool claude --model future-claude 1
)"
[[ "$(cat "$calls_file")" == "claude" ]] || {
  printf 'expected Claude work invocation when version is unknown\n%s\n' "$output" >&2
  exit 1
}
[[ "$output" != *"requires claude CLI"* ]] || {
  printf 'unknown CLI version caused a false minimum-version failure\n%s\n' "$output" >&2
  exit 1
}

echo "CLI capability preflight regression: pass"
