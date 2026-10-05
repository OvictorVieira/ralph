# Ralph Agent Instructions

## Overview

Ralph is an autonomous AI agent loop that runs AI coding tools (Amp, Claude Code, Codex CLI, Antigravity, Cursor Agent, OpenCode) repeatedly until all PRD items are complete. Each iteration is a fresh instance with clean context.

## Commands

```bash
# Run the flowchart dev server
cd flowchart && npm run dev

# Build the flowchart
cd flowchart && npm run build

# Run Ralph with Amp (default)
./ralph.sh [max_iterations]

# Run Ralph with Claude Code
./ralph.sh --tool claude [max_iterations]

# Run Ralph with Codex CLI
./ralph.sh --tool codex [max_iterations]

# Install Ralph globally
./install.sh

# Run Ralph from any project after installation
ralph --tool claude [max_iterations]
ralph --tool codex [max_iterations]
```

## Key Files

- `ralph.sh` - The bash loop that spawns fresh AI instances (supports `--tool amp`, `--tool claude`, `--tool codex`, `--tool agy`, `--tool cursor`, `--tool opencode`)
- `bin/ralph` - Global launcher installed into `~/.local/bin/ralph`
- `AMP.md` - Instructions given to each AMP instance
- `CLAUDE.md` - Instructions given to each Claude Code instance
- `CODEX.md` - Instructions given to each Codex CLI instance
- `prd.json.example` - Example PRD format
- `install.sh` - Installs Ralph globally to `~/.local`
- `uninstall.sh` - Removes the global Ralph installation
- `flowchart/` - Interactive React Flow diagram explaining how Ralph works

## Flowchart

The `flowchart/` directory contains an interactive visualization built with React Flow. It's designed for presentations - click through to reveal each step with animations.

To run locally:
```bash
cd flowchart
npm install
npm run dev
```

## Patterns

- Each iteration spawns a fresh AI instance (Amp, Claude Code, Codex CLI, Antigravity, Cursor Agent, OpenCode) with clean context
- Memory persists via git history, `progress.txt`, and `prd.json`
- Installed Ralph reads `prd.json` and `progress.txt` from the current project root, while its prompt files live in the global install directory
- Stories should be small enough to complete in one context window
- AGY structured model discovery uses the root-level form `agy --output-format json models`; AGY writes `--help` to stderr, model ids live at `.command.data.models[].id`, and text discovery remains the fallback because older releases advertised the flag without implementing subcommand output
- CLI minimum-version gates are best-effort: extract dotted numeric versions from `<tool> --version`, compare them in Bash for macOS portability, and skip the gate when the installed version is undetectable
- Banner catalog lookups use `MODEL_RESOLVED` so configured defaults are described without forcing `--model`; extra catalog metadata stays limited to claude/codex/agy to preserve legacy provider output
- Always update AGENTS.md with discovered patterns for future iterations
