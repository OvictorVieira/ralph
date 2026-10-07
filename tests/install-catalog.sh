#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

install_root="$test_root/install"
project_dir="$test_root/unrelated-project"
fake_bin="$test_root/bin"
fake_home="$test_root/home"
mkdir -p "$project_dir" "$fake_bin" "$fake_home"

RALPH_INSTALL_ROOT="$install_root" "$repo_root/install.sh" >/dev/null

installed_catalog="$install_root/share/ralph/config/models.json"

if [[ ! -f "$installed_catalog" ]]; then
  printf 'install.sh did not install config/models.json to %s\n' "$installed_catalog" >&2
  exit 1
fi

if ! diff -q "$repo_root/config/models.json" "$installed_catalog" >/dev/null; then
  printf 'installed catalog differs from repo source\n' >&2
  exit 1
fi

# A no-op claude binary is enough to be "installed"; runtime model discovery
# degrades gracefully with no advertised models (see tool_advertised_models).
cat > "$fake_bin/claude" <<'FAKE_CLAUDE'
#!/usr/bin/env bash
exit 0
FAKE_CLAUDE
chmod +x "$fake_bin/claude"

# Run the installed copy (not the repo checkout) from an unrelated directory
# with no RALPH_CATALOG_FILE override, so resolve_catalog_file must find the
# catalog installed next to the installed ralph.sh ($SHARE_DIR/config).
output="$(
  cd "$project_dir" && \
  HOME="$fake_home" \
  PATH="$fake_bin:$PATH" \
  "$install_root/share/ralph/ralph.sh" --tool claude --list-models 2>&1
)"

assert_contains() {
  local expected="$1"
  [[ "$output" == *"$expected"* ]] || {
    printf 'missing expected output: %s\n%s\n' "$expected" "$output" >&2
    exit 1
  }
}

assert_contains "  claude   (installed)"
assert_contains "MODEL"
assert_contains "STATUS"
assert_contains "claude-sonnet-5"
assert_contains "active"

echo "install-catalog regression: pass"
