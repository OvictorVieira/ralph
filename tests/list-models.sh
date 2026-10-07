#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

fake_bin="$test_root/bin"
fake_home="$test_root/home"
catalog_file="$test_root/models.json"
mkdir -p "$fake_bin" "$fake_home/.claude"

cat > "$fake_home/.claude/settings.json" <<'JSON'
{"model":"known-alias"}
JSON

cat > "$catalog_file" <<'JSON'
{
  "schemaVersion": 1,
  "providers": {
    "claude": {
      "cliBinary": "claude",
      "effortMechanism": "test",
      "models": {
        "catalog-model": {
          "label": "Catalog Model",
          "status": "active",
          "efforts": ["low", "high"],
          "defaultEffort": "high",
          "aliases": ["known-alias"],
          "successor": null,
          "minCliVersion": null,
          "source": null,
          "notes": null
        },
        "offline-model": {
          "label": "Offline Model",
          "status": "deprecated",
          "efforts": [],
          "defaultEffort": null,
          "aliases": [],
          "successor": "catalog-model",
          "minCliVersion": null,
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
if [[ "${1:-}" == "--help" ]]; then
  echo "  --model <model>  Model alias ('known-alias', 'runtime-only')."
fi
FAKE_CLAUDE
chmod +x "$fake_bin/claude"

run_ralph() {
  HOME="$fake_home" \
    PATH="$fake_bin:$PATH" \
    RALPH_CATALOG_FILE="$catalog_file" \
    "$repo_root/ralph.sh" "$@" 2>&1
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

# Filtering works regardless of whether --list-models appears before or after
# the explicit tool selector.
filtered="$(run_ralph --tool claude --list-models)"
reverse_filtered="$(run_ralph --list-models --tool claude)"
assert_contains "$filtered" "  claude   (installed)"
assert_not_contains "$filtered" "  amp      ("
[[ "$filtered" == "$reverse_filtered" ]] || {
  printf '%s\n' "--list-models filtering depends on argument order" >&2
  exit 1
}

assert_contains "$filtered" "MODEL"
assert_contains "$filtered" "STATUS"
assert_contains "$filtered" "EFFORTS"
assert_contains "$filtered" "DEFAULT"
assert_contains "$filtered" "* catalog-model"
assert_contains "$filtered" "active"
assert_contains "$filtered" "low high"
assert_contains "$filtered" "Runtime discovered: runtime-only"
assert_contains "$filtered" "Catalog only: offline-model"
assert_not_contains "$filtered" "Catalog only: catalog-model"

# With no explicit tool, all providers remain listed. Providers without a
# catalog retain the legacy presentation.
all_models="$(run_ralph --list-models)"
assert_contains "$all_models" "  claude   (installed)"
assert_contains "$all_models" "  amp      (not installed)"

amp_only="$(run_ralph --tool amp --list-models)"
assert_contains "$amp_only" "no model list available from this CLI — any value is passed through"
assert_contains "$amp_only" "effort             : not supported by this CLI"
assert_not_contains "$amp_only" "MODEL"

# Listing output is plain text when piped/captured.
if printf '%s' "$filtered" | LC_ALL=C grep -q $'\033'; then
  printf '%s\n' "non-TTY --list-models output contains ANSI escapes" >&2
  exit 1
fi

echo "list-models regression: pass"
