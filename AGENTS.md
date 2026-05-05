# Ralph Agent Instructions

## Overview

Ralph is an autonomous AI agent loop that runs AI coding tools (Amp, Claude Code, Gemini CLI, or Codex CLI) repeatedly until all PRD items are complete. Each iteration is a fresh instance with clean context.

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

# Run Ralph with Gemini CLI
./ralph.sh --tool gemini [max_iterations]

# Run Ralph with Codex CLI
./ralph.sh --tool codex [max_iterations]

# Install Ralph globally
./install.sh

# Run Ralph from any project after installation
ralph --tool claude [max_iterations]
ralph --tool gemini [max_iterations]
ralph --tool codex [max_iterations]
```

## Key Files

- `ralph.sh` - The bash loop that spawns fresh AI instances (supports `--tool amp`, `--tool claude`, `--tool gemini`, or `--tool codex`)
- `bin/ralph` - Global launcher installed into `~/.local/bin/ralph`
- `AMP.md` - Instructions given to each AMP instance
- `CLAUDE.md` - Instructions given to each Claude Code instance
- `GEMINI.md` - Instructions given to each Gemini CLI instance
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

- Each iteration spawns a fresh AI instance (Amp, Claude Code, Gemini CLI, or Codex CLI) with clean context
- Memory persists via git history, `progress.txt`, and `prd.json`
- Installed Ralph reads `prd.json` and `progress.txt` from the current project root, while its prompt files live in the global install directory
- Stories should be small enough to complete in one context window
- Always update AGENTS.md with discovered patterns for future iterations
