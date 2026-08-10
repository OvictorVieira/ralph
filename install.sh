#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_ROOT="${RALPH_INSTALL_ROOT:-$HOME/.local}"
BIN_DIR="$INSTALL_ROOT/bin"
SHARE_DIR="$INSTALL_ROOT/share/ralph"

mkdir -p "$BIN_DIR" "$SHARE_DIR"

install -m 755 "$SCRIPT_DIR/ralph.sh" "$SHARE_DIR/ralph.sh"
install -m 644 "$SCRIPT_DIR/AMP.md" "$SHARE_DIR/AMP.md"
install -m 644 "$SCRIPT_DIR/CLAUDE.md" "$SHARE_DIR/CLAUDE.md"
install -m 644 "$SCRIPT_DIR/GEMINI.md" "$SHARE_DIR/GEMINI.md"
install -m 644 "$SCRIPT_DIR/CODEX.md" "$SHARE_DIR/CODEX.md"
install -m 644 "$SCRIPT_DIR/AGY.md" "$SHARE_DIR/AGY.md"
install -m 644 "$SCRIPT_DIR/CURSOR.md" "$SHARE_DIR/CURSOR.md"
install -m 644 "$SCRIPT_DIR/OPENCODE.md" "$SHARE_DIR/OPENCODE.md"
install -m 644 "$SCRIPT_DIR/prd.json.example" "$SHARE_DIR/prd.json.example"
install -m 755 "$SCRIPT_DIR/bin/ralph" "$BIN_DIR/ralph"

echo "Ralph installed."
echo "  Binary: $BIN_DIR/ralph"
echo "  Files:  $SHARE_DIR"
echo ""
echo "Make sure $BIN_DIR is in your PATH."
echo "Run from any project root:"
echo "  ralph --tool claude"
echo "  ralph --tool amp"
echo "  ralph --tool gemini"
echo "  ralph --tool codex"
