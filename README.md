# Ralph

![Ralph](ralph.webp)

Ralph is an autonomous AI agent loop that runs AI coding tools ([Claude Code](https://docs.anthropic.com/en/docs/claude-code), Codex CLI, Antigravity, Cursor Agent, OpenCode, [Amp](https://ampcode.com), or Gemini CLI) repeatedly until all PRD items are complete. Each iteration is a fresh instance with clean context. Memory persists via git history, `progress.txt`, and `prd.json`.

Based on [Geoffrey Huntley's Ralph pattern](https://ghuntley.com/ralph/).

[Read my in-depth article on how I use Ralph](https://x.com/ryancarson/status/2008548371712135632)

## Prerequisites

- One of the following AI coding tools installed and authenticated:
  - [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (`npm install -g @anthropic-ai/claude-code`)
  - Codex CLI
  - Antigravity (`agy`)
  - Cursor Agent (`cursor-agent`)
  - [OpenCode](https://github.com/sst/opencode)
  - [Amp CLI](https://ampcode.com) (the historical default)
  - Gemini CLI (superseded by Antigravity)
- `jq` installed (`brew install jq` on macOS)
- A git repository for your project

## Setup

### Option 1: Install Ralph globally

Clone this repo and install Ralph into `~/.local`:

```bash
git clone https://github.com/YOUR_USERNAME/ralph.git
cd ralph
./install.sh
```

This installs:
- `~/.local/bin/ralph`
- `~/.local/share/ralph/ralph.sh`
- `~/.local/share/ralph/AMP.md`
- `~/.local/share/ralph/CLAUDE.md`
- `~/.local/share/ralph/GEMINI.md`
- `~/.local/share/ralph/CODEX.md`
- `~/.local/share/ralph/AGY.md`
- `~/.local/share/ralph/CURSOR.md`
- `~/.local/share/ralph/OPENCODE.md`

If `~/.local/bin` is not already in your `PATH`, add this to `~/.zshenv` or your shell profile:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Then open a new terminal and run Ralph from any project root:

```bash
ralph --tool claude
ralph --tool codex
ralph --tool agy
ralph --tool cursor
ralph --tool opencode
```

Ralph automatically:
- detects the current project root from git or `prd.json`
- reads `prd.json` and `progress.txt` from that project
- stores its own run metadata in `.ralph/`
- keeps the shared prompts in the global install directory

### Option 2: Copy to your project manually

If you do not want a global install, copy the Ralph files into your project:

```bash
# From your project root
mkdir -p scripts/ralph
cp /path/to/ralph/ralph.sh scripts/ralph/
cp /path/to/ralph/AMP.md scripts/ralph/AMP.md
cp /path/to/ralph/CLAUDE.md scripts/ralph/CLAUDE.md
cp /path/to/ralph/GEMINI.md scripts/ralph/GEMINI.md
cp /path/to/ralph/CODEX.md scripts/ralph/CODEX.md
cp /path/to/ralph/AGY.md scripts/ralph/AGY.md
cp /path/to/ralph/CURSOR.md scripts/ralph/CURSOR.md
cp /path/to/ralph/OPENCODE.md scripts/ralph/OPENCODE.md

chmod +x scripts/ralph/ralph.sh
```

### Option 3: Install skills globally

Copy the skills to your Amp or Claude config for use across all projects:

For AMP
```bash
cp -r skills/prd ~/.config/amp/skills/
cp -r skills/ralph ~/.config/amp/skills/
```

For Claude Code (manual)
```bash
cp -r skills/prd ~/.claude/skills/
cp -r skills/ralph ~/.claude/skills/
```

### Option 4: Use as Claude Code Marketplace

Add the Ralph marketplace to Claude Code:

```bash
/plugin marketplace add snarktank/ralph
```

Then install the skills:

```bash
/plugin install ralph-skills@ralph-marketplace
```

Available skills after installation:
- `/prd` - Generate Product Requirements Documents
- `/ralph` - Convert PRDs to prd.json format

Skills are automatically invoked when you ask Claude to:
- "create a prd", "write prd for", "plan this feature"
- "convert this prd", "turn into ralph format", "create prd.json"

### Configure Amp auto-handoff (recommended)

Add to `~/.config/amp/settings.json`:

```json
{
  "amp.experimental.autoHandoff": { "context": 90 }
}
```

This enables automatic handoff when context fills up, allowing Ralph to handle large stories that exceed a single context window.

## Workflow

### 1. Create a PRD

Use the PRD skill to generate a detailed requirements document:

```
Load the prd skill and create a PRD for [your feature description]
```

Answer the clarifying questions. The skill saves output to `tasks/prd-[feature-name].md`.

### 2. Convert PRD to Ralph format

Use the Ralph skill to convert the markdown PRD to JSON:

```
Load the ralph skill and convert tasks/prd-[feature-name].md to prd.json
```

This creates `prd.json` with user stories structured for autonomous execution.

### 3. Run Ralph

```bash
# Using a global install
ralph [max_iterations]

# Using Claude Code with a global install
ralph --tool claude [max_iterations]

# Using Codex with a global install
ralph --tool codex [max_iterations]

# Using Antigravity, Cursor or OpenCode with a global install
ralph --tool agy [max_iterations]
ralph --tool cursor [max_iterations]
ralph --tool opencode [max_iterations]

# Using a project-local copy
./scripts/ralph/ralph.sh [max_iterations]

# Using a project-local copy with Claude Code
./scripts/ralph/ralph.sh --tool claude [max_iterations]

# Using a project-local copy with Codex
./scripts/ralph/ralph.sh --tool codex [max_iterations]
```

Default is 10 iterations. See the tool table below for what each one supports.

### Tools

| Tool | Binary | Model | Effort |
|------|--------|-------|--------|
| `claude` | `claude` | `--model` | `--effort` — low, medium, high, xhigh, max |
| `codex` | `codex` | `--model` | `model_reasoning_effort` key — minimal, low, medium, high, xhigh |
| `agy` | `agy` (Antigravity) | `--model` | `--effort` — low, medium, high |
| `cursor` | `cursor-agent` | `--model` | `model[effort=…]` — needs `--model` |
| `opencode` | `opencode` | `-m provider/model` | `--variant` |
| `amp` | `amp` | `--model` | none |
| `gemini` | `gemini` | `--model` | none — superseded by `agy` |

`opencode` is found at `~/.opencode/bin/opencode` when it is not on PATH.

### Models

Ralph pins no model. Each tool runs whatever it is already configured with, so a
new model is available the day the vendor ships it, without a Ralph release.

```bash
ralph --list-models                                        # everything below, per tool
ralph --claude --model sonnet
ralph --codex  --model gpt-5.6-sol
ralph --opencode --model opencode/deepseek-v4-flash-free
```

`--list-models` asks the installed CLIs — `opencode models`, `agy models`,
`cursor-agent --list-models`, the aliases in `claude --help`, the `model` key in
`~/.codex/config.toml` — rather than printing a table baked into Ralph that would
go stale. Where a CLI exposes no list, or needs a sign-in it does not have, it
says so instead of guessing.

`--model` is passed to the tool as given. When the tool can enumerate its models
and yours is not among them, Ralph warns and runs it anyway: a full model id is
frequently valid without being advertised.

### Effort

One vocabulary — `low`, `medium`, `high`, `xhigh`, `max` — translated per tool,
because no two of these CLIs spell it the same way or even use the same
mechanism. A level the chosen tool does not accept is an error, not a silent
downgrade:

```bash
ralph --claude --effort xhigh 8
ralph --codex  --effort high 8
ralph --agy    --effort high 8
ralph --cursor --model sonnet-4-thinking --effort high 8   # effort rides in the model string
ralph --opencode --model opencode/big-pickle --effort high 8

ralph --agy --effort xhigh
# Error: 'agy' does not accept effort 'xhigh'.
#        Accepts: low medium high  (via --effort flag)
```

Every range above came from the CLI itself — `claude --effort bogus` names its
valid values, `agy --help` documents its own, `cursor-agent --help` shows the
bracket-override form. Amp and Gemini have no such knob at all, so `--effort`
there is rejected rather than dropped.

### Branches

Ralph does not name branches — the project's convention does.

- Already on a working branch (a worktree, a release branch, anything but the
  default): **that** is the branch. Ralph records it and the agent stays on it.
- On the default branch: the agent reads `AGENTS.md` / `CONTRIBUTING.md` / recent
  branch names, falls back to git flow when the project documents nothing, and
  creates a short branch — a few kebab-case words, no story ids, never a `ralph/`
  prefix.

Ralph will:
1. Adopt the checked-out working branch, or let the agent create one per the project's convention
2. Pick the highest priority story where `passes: false`
3. Implement that single story
4. Run quality checks (typecheck, tests)
5. Commit if checks pass
6. Update `prd.json` to mark story as `passes: true`
7. Append learnings to `progress.txt`
8. Repeat until all stories pass or max iterations reached

## Key Files

| File | Purpose |
|------|---------|
| `ralph.sh` | The bash loop that spawns fresh AI instances (see the tool table above) |
| `bin/ralph` | Global launcher installed to `~/.local/bin/ralph` |
| `AMP.md` | Prompt template for Amp |
| `AGY.md` | Prompt template for Antigravity |
| `CURSOR.md` | Prompt template for Cursor Agent |
| `OPENCODE.md` | Prompt template for OpenCode |
| `CLAUDE.md` | Prompt template for Claude Code |
| `GEMINI.md` | Prompt template for Gemini CLI |
| `CODEX.md` | Prompt template for Codex CLI |
| `prd.json` | User stories with `passes` status (the task list) |
| `prd.json.example` | Example PRD format for reference |
| `progress.txt` | Append-only learnings for future iterations |
| `.ralph/` | Ralph metadata and archives stored per target project |
| `install.sh` | Installs Ralph globally into `~/.local` |
| `uninstall.sh` | Removes the global Ralph installation |
| `skills/prd/` | Skill for generating PRDs (works with Amp and Claude Code) |
| `skills/ralph/` | Skill for converting PRDs to JSON (works with Amp and Claude Code) |
| `.claude-plugin/` | Plugin manifest for Claude Code marketplace discovery |
| `flowchart/` | Interactive visualization of how Ralph works |

## Flowchart

[![Ralph Flowchart](ralph-flowchart.png)](https://snarktank.github.io/ralph/)

**[View Interactive Flowchart](https://snarktank.github.io/ralph/)** - Click through to see each step with animations.

The `flowchart/` directory contains the source code. To run locally:

```bash
cd flowchart
npm install
npm run dev
```

## Critical Concepts

### Each Iteration = Fresh Context

Each iteration spawns a **new AI instance** (whichever tool `--tool` selected) with clean context. The only memory between iterations is:
- Git history (commits from previous iterations)
- `progress.txt` (learnings and context)
- `prd.json` (which stories are done)

### Small Tasks

Each PRD item should be small enough to complete in one context window. If a task is too big, the LLM runs out of context before finishing and produces poor code.

Right-sized stories:
- Add a database column and migration
- Add a UI component to an existing page
- Update a server action with new logic
- Add a filter dropdown to a list

Too big (split these):
- "Build the entire dashboard"
- "Add authentication"
- "Refactor the API"

### AGENTS.md Updates Are Critical

After each iteration, Ralph updates the relevant `AGENTS.md` files with learnings. This is key because AI coding tools automatically read these files, so future iterations (and future human developers) benefit from discovered patterns, gotchas, and conventions.

Examples of what to add to AGENTS.md:
- Patterns discovered ("this codebase uses X for Y")
- Gotchas ("do not forget to update Z when changing W")
- Useful context ("the settings panel is in component X")

### Feedback Loops

Ralph only works if there are feedback loops:
- Typecheck catches type errors
- Tests verify behavior
- CI must stay green (broken code compounds across iterations)

### Browser Verification for UI Stories

Frontend stories must include "Verify in browser using dev-browser skill" in acceptance criteria. Ralph will use the dev-browser skill to navigate to the page, interact with the UI, and confirm changes work.

### Stop Condition

When all stories have `passes: true`, Ralph outputs `<promise>COMPLETE</promise>` and the loop exits.

## Debugging

Check current state:

```bash
# See which stories are done
cat prd.json | jq '.userStories[] | {id, title, passes}'

# See learnings from previous iterations
cat progress.txt

# Check git history
git log --oneline -10
```

## Customizing the Prompt

After copying `AMP.md` (for Amp) or `CLAUDE.md` (for Claude Code) to your project, customize it for your project:
- Add project-specific quality check commands
- Include codebase conventions
- Add common gotchas for your stack

If you use the global install and want custom prompts per machine, edit the files in `~/.local/share/ralph/`.

## Archiving

Ralph automatically archives previous runs when you start a new feature (different `branchName`). Archives are saved to `.ralph/archive/YYYY-MM-DD-feature-name/` inside the target project.

## References

- [Geoffrey Huntley's Ralph article](https://ghuntley.com/ralph/)
- [Amp documentation](https://ampcode.com/manual)
- [Claude Code documentation](https://docs.anthropic.com/en/docs/claude-code)
