#!/bin/bash

set -euo pipefail

INSTALL_ROOT="${RALPH_INSTALL_ROOT:-$HOME/.local}"
BIN_PATH="$INSTALL_ROOT/bin/ralph"
SHARE_DIR="$INSTALL_ROOT/share/ralph"

if [[ -e "$BIN_PATH" ]]; then
  rm "$BIN_PATH"
  echo "Removed $BIN_PATH"
fi

if [[ -d "$SHARE_DIR" ]]; then
  rm -rf "$SHARE_DIR"
  echo "Removed $SHARE_DIR"
fi

echo "Ralph uninstalled."
