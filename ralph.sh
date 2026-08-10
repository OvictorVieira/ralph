#!/bin/bash
# Ralph Wiggum - Long-running AI agent loop
# Usage: ralph [--tool amp|claude|gemini|codex] [max_iterations]

set -euo pipefail

print_usage() {
  cat <<'EOF'
Usage: ralph [--tool amp|claude|gemini|codex] [--model MODEL]
             [--effort low|medium|high|max] [max_iterations]

Options:
  --tool TOOL        Agent to run. Supported: amp, claude, gemini, codex
  --tool=TOOL        Same as above
  --claude           Shortcut for --tool claude
  --amp              Shortcut for --tool amp
  --gemini           Shortcut for --tool gemini
  --codex            Shortcut for --tool codex
  --model MODEL      Model to run. Defaults to the tool's own configured model.
  --model=MODEL      Same as above
  --list-models      Show, per tool, the model it is configured with and any it
                     advertises. Queries the installed CLIs rather than a table
                     baked into Ralph.
  --effort LEVEL     Reasoning effort (low, medium, high, max). Default: medium.
                     Supported by claude and codex; rejected for the others
                     instead of being silently dropped.
  --effort=LEVEL     Same as above
  -h, --help         Show this help message

Arguments:
  max_iterations     Number of Ralph loop iterations. Default: 10

Environment:
  RALPH_PROJECT_ROOT Override the project root used for prd.json/progress.txt

Branches:
  Ralph does not name branches. On a working branch, that branch is the target.
  On the default branch, the agent reads the project's own convention and
  creates a short git-flow branch itself.
EOF
}

resolve_script_dir() {
  local source_path="${BASH_SOURCE[0]}"

  while [[ -L "$source_path" ]]; do
    local source_dir
    source_dir="$(cd -P "$(dirname "$source_path")" && pwd)"
    source_path="$(readlink "$source_path")"

    if [[ "$source_path" != /* ]]; then
      source_path="$source_dir/$source_path"
    fi
  done

  cd -P "$(dirname "$source_path")" && pwd
}

detect_project_root() {
  if [[ -n "${RALPH_PROJECT_ROOT:-}" ]]; then
    echo "$RALPH_PROJECT_ROOT"
    return 0
  fi

  if command -v git >/dev/null 2>&1; then
    local git_root
    git_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ -n "$git_root" ]]; then
      echo "$git_root"
      return 0
    fi
  fi

  local dir="$PWD"
  while [[ "$dir" != "/" ]]; do
    if [[ -f "$dir/prd.json" || -d "$dir/.git" ]]; then
      echo "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done

  echo "$PWD"
}

resolve_prd_file() {
  local project_root="$1"

  if [[ -f "$project_root/prd.json" ]]; then
    echo "$project_root/prd.json"
    return 0
  fi

  if [[ -f "$project_root/tasks/prd.json" ]]; then
    echo "$project_root/tasks/prd.json"
    return 0
  fi

  return 1
}

# Ralph does not invent branch names.
#
# It used to: a chain of infer_branch_type / infer_ticket_key / infer_branch_slug
# synthesised a name from the PRD and overwrote whatever the PRD declared. That
# produced names no project asked for — `hotfix/US-004/15-regression-harness-defects`
# from a PRD that plainly said `fix/15-regression-harness-defects`, because the
# type table mapped `fix/*` to `hotfix` and a story id in the description was
# mistaken for a ticket key. Worse, the agent prompt then read the rewritten
# value and created that branch from main, which breaks any repo that pins a
# branch per worktree.
#
# The project owns its branch convention. Two rules replace the guessing:
#
#   1. Already on a working branch (anything but the default) — that IS the
#      target. Record it, never rename it.
#   2. On the default branch — Ralph declines to name anything. The agent reads
#      the project's own convention (AGENTS.md, CLAUDE.md, CONTRIBUTING.md,
#      recent branch names) and creates a short git-flow branch itself.
detect_default_branch() {
  local project_root="$1"
  local head_ref

  head_ref="$(
    git -C "$project_root" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null \
      || true
  )"

  if [[ -n "$head_ref" ]]; then
    echo "${head_ref#origin/}"
    return 0
  fi

  if git -C "$project_root" show-ref --verify --quiet refs/remotes/origin/main \
    || git -C "$project_root" show-ref --verify --quiet refs/heads/main; then
    echo "main"
    return 0
  fi

  if git -C "$project_root" show-ref --verify --quiet refs/remotes/origin/master \
    || git -C "$project_root" show-ref --verify --quiet refs/heads/master; then
    echo "master"
    return 0
  fi

  echo "main"
}

# Prints the branch Ralph should record in the PRD, or nothing when the agent
# must choose one. Never invents a name.
resolve_target_branch() {
  local project_root="$1"
  local prd_file="$2"
  local checked_out default_branch declared

  command -v git >/dev/null 2>&1 || return 0
  git -C "$project_root" rev-parse --git-dir >/dev/null 2>&1 || return 0

  checked_out="$(git -C "$project_root" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  default_branch="$(detect_default_branch "$project_root")"

  # Detached HEAD reports literal "HEAD" — there is no branch to adopt.
  if [[ -n "$checked_out" && "$checked_out" != "HEAD" && "$checked_out" != "$default_branch" ]]; then
    echo "$checked_out"
    return 0
  fi

  # On the default branch the PRD may still name a branch the agent should
  # create — but only if it follows the project's convention rather than
  # Ralph's own namespace. `ralph/...` is never a project convention.
  declared="$(jq -r '.branchName // empty' "$prd_file" 2>/dev/null || true)"
  if [[ -n "$declared" && ! "$declared" =~ ^ralph(/|$) ]]; then
    echo "$declared"
  fi
}

persist_branch_name() {
  local prd_file="$1"
  local branch_name="$2"
  local tmp_file

  tmp_file="$(mktemp)"
  jq --arg branch_name "$branch_name" '.branchName = $branch_name' "$prd_file" > "$tmp_file"
  mv "$tmp_file" "$prd_file"
}

resolve_git_identity_from_history() {
  local project_root="$1"
  local preferred_name="$2"
  local recent_identity
  local history_ref

  if [[ -z "$preferred_name" ]]; then
    return 0
  fi

  history_ref="$(
    git -C "$project_root" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null \
      || true
  )"

  if [[ -z "$history_ref" ]]; then
    if git -C "$project_root" show-ref --verify --quiet refs/remotes/origin/main; then
      history_ref="origin/main"
    elif git -C "$project_root" show-ref --verify --quiet refs/heads/main; then
      history_ref="main"
    elif git -C "$project_root" show-ref --verify --quiet refs/heads/master; then
      history_ref="master"
    else
      history_ref="HEAD"
    fi
  fi

  recent_identity="$(
    git -C "$project_root" log "$history_ref" --format='%an%x09%ae' 2>/dev/null \
      | awk -F '\t' -v preferred_name="$preferred_name" '
          $1 == preferred_name && $2 !~ /local$/ { print $0; exit }
        '
  )"

  if [[ -n "$recent_identity" ]]; then
    printf '%s\n' "$recent_identity"
  fi
}

SUPPORTED_TOOLS="amp claude gemini codex"

# Which tools can actually be told how hard to think, and how.
#
# Passing --effort to a tool that has no such knob used to be silently accepted
# and silently dropped: the flag only ever reached claude. Now the unsupported
# combination says so.
tool_supports_effort() {
  case "$1" in
    claude|codex) return 0 ;;
    *) return 1 ;;
  esac
}

# Model discovery is per-tool because no two of these CLIs expose it the same
# way, and none of them offers a machine-readable list. Rather than hardcode a
# table that rots the moment a vendor ships a model, ask each CLI what it knows
# and say plainly where the answer came from — including when the answer is
# "it does not tell us".
tool_configured_model() {
  case "$1" in
    claude)
      [[ -f "$HOME/.claude/settings.json" ]] || return 0
      jq -r '.model // empty' "$HOME/.claude/settings.json" 2>/dev/null || true
      ;;
    codex)
      [[ -f "$HOME/.codex/config.toml" ]] || return 0
      sed -n 's/^[[:space:]]*model[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
        "$HOME/.codex/config.toml" 2>/dev/null | head -n 1
      ;;
    gemini)
      [[ -f "$HOME/.gemini/settings.json" ]] || return 0
      jq -r '.model // .model.name // empty' "$HOME/.gemini/settings.json" 2>/dev/null || true
      ;;
  esac
}

# Claude Code documents its aliases and one full model id inside `--model`'s
# own help text. That is the only self-describing source any of these CLIs has,
# so parse it rather than guess.
tool_advertised_models() {
  case "$1" in
    claude)
      command -v claude >/dev/null 2>&1 || return 0
      claude --help 2>/dev/null \
        | awk '/--model </{capture=1} capture{print} capture && /\)\./{exit}' \
        | grep -Eo "'[a-zA-Z0-9._-]+'" \
        | tr -d "'" \
        | sort -u \
        | tr '\n' ' '
      ;;
  esac
}

print_models() {
  local tool configured advertised installed

  echo "Models"
  echo ""
  for tool in $SUPPORTED_TOOLS; do
    if command -v "$tool" >/dev/null 2>&1; then
      installed="installed"
    else
      installed="not installed"
    fi

    printf '  %-8s (%s)\n' "$tool" "$installed"

    configured="$(tool_configured_model "$tool" || true)"
    if [[ -n "$configured" ]]; then
      printf '    configured default : %s\n' "$configured"
    fi

    advertised="$(tool_advertised_models "$tool" || true)"
    if [[ -n "${advertised// /}" ]]; then
      printf '    advertised by CLI  : %s\n' "${advertised% }"
    fi

    if [[ -z "$configured" && -z "${advertised// /}" ]]; then
      printf '    %s\n' "no model list available from this CLI — any value is passed through"
    fi

    if tool_supports_effort "$tool"; then
      printf '    effort             : supported\n'
    else
      printf '    effort             : not supported by this CLI\n'
    fi
    echo ""
  done
  cat <<'EOF'
--model accepts any value the tool accepts; Ralph does not validate it.
With no --model, each tool uses its own configured default rather than one
Ralph picked for you.
EOF
}

# Parse arguments
TOOL="amp"  # Default to amp for backwards compatibility
MAX_ITERATIONS=10
EFFORT="medium"
EFFORT_EXPLICIT=0
MODEL=""

while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)
      print_usage
      exit 0
      ;;
    --claude)
      TOOL="claude"
      shift
      ;;
    --amp)
      TOOL="amp"
      shift
      ;;
    --gemini)
      TOOL="gemini"
      shift
      ;;
    --codex)
      TOOL="codex"
      shift
      ;;
    --tool)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "Error: --tool requires a value."
        print_usage
        exit 1
      fi
      TOOL="$2"
      shift 2
      ;;
    --tool=*)
      TOOL="${1#*=}"
      shift
      ;;
    --effort)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "Error: --effort requires a value (low, medium, high, max)."
        print_usage
        exit 1
      fi
      EFFORT="$2"
      EFFORT_EXPLICIT=1
      shift 2
      ;;
    --effort=*)
      EFFORT="${1#*=}"
      EFFORT_EXPLICIT=1
      shift
      ;;
    --model)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "Error: --model requires a value. See 'ralph --list-models'."
        exit 1
      fi
      MODEL="$2"
      shift 2
      ;;
    --model=*)
      MODEL="${1#*=}"
      shift
      ;;
    --list-models)
      print_models
      exit 0
      ;;
    *)
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        MAX_ITERATIONS="$1"
      else
        echo "Error: Unknown argument '$1'."
        print_usage
        exit 1
      fi
      shift
      ;;
  esac
done

# Validate tool choice
if [[ "$TOOL" != "amp" && "$TOOL" != "claude" && "$TOOL" != "gemini" && "$TOOL" != "codex" ]]; then
  echo "Error: Invalid tool '$TOOL'. Must be 'amp', 'claude', 'gemini', or 'codex'."
  exit 1
fi

if [[ "$EFFORT_EXPLICIT" -eq 1 ]] && ! tool_supports_effort "$TOOL"; then
  echo "Error: --effort is not supported by '$TOOL'."
  echo "       Supported: claude (--effort), codex (model_reasoning_effort)."
  echo "       Run 'ralph --list-models' to see what each installed tool exposes."
  exit 1
fi

SCRIPT_DIR="$(resolve_script_dir)"
PROJECT_ROOT="$(detect_project_root)"
PRD_FILE="$(resolve_prd_file "$PROJECT_ROOT" || true)"
PROGRESS_FILE="$PROJECT_ROOT/progress.txt"
STATE_DIR="$PROJECT_ROOT/.ralph"
ARCHIVE_DIR="$STATE_DIR/archive"
LAST_BRANCH_FILE="$STATE_DIR/.last-branch"

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required but was not found in PATH."
  exit 1
fi

if [[ "$TOOL" == "claude" ]] && ! command -v claude >/dev/null 2>&1; then
  echo "Error: claude is required but was not found in PATH."
  exit 1
fi

if [[ "$TOOL" == "amp" ]] && ! command -v amp >/dev/null 2>&1; then
  echo "Error: amp is required but was not found in PATH."
  exit 1
fi

if [[ "$TOOL" == "gemini" ]] && ! command -v gemini >/dev/null 2>&1; then
  echo "Error: gemini is required but was not found in PATH."
  exit 1
fi

if [[ "$TOOL" == "codex" ]] && ! command -v codex >/dev/null 2>&1; then
  echo "Error: codex is required but was not found in PATH."
  exit 1
fi

if [[ -z "$PRD_FILE" || ! -f "$PRD_FILE" ]]; then
  echo "Error: Could not find prd.json in project root or tasks/: $PROJECT_ROOT"
  echo "Run Ralph from inside a project that has prd.json or tasks/prd.json, or set RALPH_PROJECT_ROOT."
  exit 1
fi

DECLARED_BRANCH_NAME="$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || true)"
TARGET_BRANCH_NAME="$(resolve_target_branch "$PROJECT_ROOT" "$PRD_FILE")"

if [[ "$DECLARED_BRANCH_NAME" =~ ^ralph(/|$) ]]; then
  echo "Warning: PRD branchName '$DECLARED_BRANCH_NAME' uses Ralph's own namespace."
  echo "         Branch names belong to the project, not to Ralph. Ignoring it —"
  echo "         the agent will follow the project's convention instead."
fi

if [[ -n "$TARGET_BRANCH_NAME" ]]; then
  if [[ "$TARGET_BRANCH_NAME" != "$DECLARED_BRANCH_NAME" ]]; then
    persist_branch_name "$PRD_FILE" "$TARGET_BRANCH_NAME"
  fi
elif [[ -n "$DECLARED_BRANCH_NAME" ]]; then
  # Only reachable when the declared name was a `ralph/...` one. Clearing it
  # stops the agent from creating it.
  persist_branch_name "$PRD_FILE" ""
fi

if command -v git >/dev/null 2>&1; then
  GIT_LOCAL_USER_NAME="$(git -C "$PROJECT_ROOT" config --local user.name 2>/dev/null || true)"
  GIT_LOCAL_USER_EMAIL="$(git -C "$PROJECT_ROOT" config --local user.email 2>/dev/null || true)"
  GIT_FALLBACK_USER_NAME="${GIT_LOCAL_USER_NAME:-$(git -C "$PROJECT_ROOT" config user.name 2>/dev/null || true)}"

  if [[ -z "$GIT_LOCAL_USER_EMAIL" ]]; then
    GIT_HISTORY_IDENTITY="$(resolve_git_identity_from_history "$PROJECT_ROOT" "$GIT_FALLBACK_USER_NAME")"
    if [[ -n "$GIT_HISTORY_IDENTITY" ]]; then
      GIT_LOCAL_USER_NAME="${GIT_HISTORY_IDENTITY%%	*}"
      GIT_LOCAL_USER_EMAIL="${GIT_HISTORY_IDENTITY#*	}"
    fi
  fi

  if [[ -n "$GIT_LOCAL_USER_NAME" ]]; then
    export GIT_AUTHOR_NAME="$GIT_LOCAL_USER_NAME"
    export GIT_COMMITTER_NAME="$GIT_LOCAL_USER_NAME"
  fi

  if [[ -n "$GIT_LOCAL_USER_EMAIL" ]]; then
    export GIT_AUTHOR_EMAIL="$GIT_LOCAL_USER_EMAIL"
    export GIT_COMMITTER_EMAIL="$GIT_LOCAL_USER_EMAIL"
  fi
fi

AMP_PROMPT_FILE_NAME="AMP.md"
CLAUDE_PROMPT_FILE_NAME="CLAUDE.md"
GEMINI_PROMPT_FILE_NAME="GEMINI.md"
CODEX_PROMPT_FILE_NAME="CODEX.md"

case "$TOOL" in
  claude) PROMPT_FILE_NAME="$CLAUDE_PROMPT_FILE_NAME" ;;
  gemini) PROMPT_FILE_NAME="$GEMINI_PROMPT_FILE_NAME" ;;
  codex)  PROMPT_FILE_NAME="$CODEX_PROMPT_FILE_NAME" ;;
  amp)    PROMPT_FILE_NAME="$AMP_PROMPT_FILE_NAME" ;;
esac

# Check for local override first, then fall back to script directory
if [[ -f "$PROJECT_ROOT/$PROMPT_FILE_NAME" ]]; then
  PROMPT_FILE="$PROJECT_ROOT/$PROMPT_FILE_NAME"
else
  PROMPT_FILE="$SCRIPT_DIR/$PROMPT_FILE_NAME"
fi

if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "Error: Missing prompt file for $TOOL: $PROMPT_FILE"
  exit 1
fi

mkdir -p "$STATE_DIR"
cd "$PROJECT_ROOT"

# Archive previous run if branch changed
if [ -f "$PRD_FILE" ] && [ -f "$LAST_BRANCH_FILE" ]; then
  CURRENT_BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
  LAST_BRANCH=$(cat "$LAST_BRANCH_FILE" 2>/dev/null || echo "")
  
  if [ -n "$CURRENT_BRANCH" ] && [ -n "$LAST_BRANCH" ] && [ "$CURRENT_BRANCH" != "$LAST_BRANCH" ]; then
    # Archive the previous run
    DATE=$(date +%Y-%m-%d)
    FOLDER_NAME=$(echo "$LAST_BRANCH" | sed 's|/|-|g')
    ARCHIVE_FOLDER="$ARCHIVE_DIR/$DATE-$FOLDER_NAME"
    
    echo "Archiving previous run: $LAST_BRANCH"
    mkdir -p "$ARCHIVE_FOLDER"
    [ -f "$PRD_FILE" ] && cp "$PRD_FILE" "$ARCHIVE_FOLDER/"
    [ -f "$PROGRESS_FILE" ] && cp "$PROGRESS_FILE" "$ARCHIVE_FOLDER/"
    echo "   Archived to: $ARCHIVE_FOLDER"
    
    # Reset progress file for new run
    echo "# Ralph Progress Log" > "$PROGRESS_FILE"
    echo "Started: $(date)" >> "$PROGRESS_FILE"
    echo "---" >> "$PROGRESS_FILE"
  fi
fi

# Track current branch
if [ -f "$PRD_FILE" ]; then
  CURRENT_BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
  if [ -n "$CURRENT_BRANCH" ]; then
    echo "$CURRENT_BRANCH" > "$LAST_BRANCH_FILE"
  fi
fi

# Initialize progress file if it doesn't exist
if [ ! -f "$PROGRESS_FILE" ]; then
  echo "# Ralph Progress Log" > "$PROGRESS_FILE"
  echo "Started: $(date)" >> "$PROGRESS_FILE"
  echo "---" >> "$PROGRESS_FILE"
fi

cd "$PROJECT_ROOT"

echo "Starting Ralph - Tool: $TOOL - Max iterations: $MAX_ITERATIONS"
echo "Project root: $PROJECT_ROOT"
echo "PRD file: $PRD_FILE"
if [[ -n "$MODEL" ]]; then
  echo "Model: $MODEL"
else
  echo "Model: ${TOOL} default ($(tool_configured_model "$TOOL" 2>/dev/null || true))"
fi
if [[ "$TOOL" == "claude" ]]; then
  echo "Effort: $EFFORT"
elif tool_supports_effort "$TOOL" && [[ "$EFFORT_EXPLICIT" -eq 1 ]]; then
  echo "Effort: $EFFORT"
elif tool_supports_effort "$TOOL"; then
  echo "Effort: ${TOOL} default (no --effort given)"
fi
RUNNING_BRANCH="$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || true)"
if [[ -n "$RUNNING_BRANCH" ]]; then
  echo "Target branch: $RUNNING_BRANCH"
else
  echo "Target branch: (agent will create one following the project's convention)"
fi
if [[ -n "${GIT_AUTHOR_EMAIL:-}" ]]; then
  echo "Commit email: $GIT_AUTHOR_EMAIL"
fi

for i in $(seq 1 $MAX_ITERATIONS); do
  echo ""
  echo "==============================================================="
  echo "  Ralph Iteration $i of $MAX_ITERATIONS ($TOOL)"
  echo "==============================================================="

  # Run the selected tool with the ralph prompt.
  #
  # No model is hardcoded. Ralph used to pin claude to `--model opus`, which
  # silently overrode the user's own configured default and went stale every
  # time a new model shipped. With no --model, each CLI uses its own default.
  if [[ "$TOOL" == "amp" ]]; then
    AMP_ARGS=(--dangerously-allow-all)
    [[ -n "$MODEL" ]] && AMP_ARGS+=(--model "$MODEL")
    OUTPUT=$(amp "${AMP_ARGS[@]}" < "$PROMPT_FILE" 2>&1 | tee /dev/stderr) || true
  elif [[ "$TOOL" == "claude" ]]; then
    # Claude Code: --dangerously-skip-permissions for autonomous operation, --print for output
    CLAUDE_ARGS=(--effort "$EFFORT" --dangerously-skip-permissions --print)
    [[ -n "$MODEL" ]] && CLAUDE_ARGS+=(--model "$MODEL")
    OUTPUT=$(claude "${CLAUDE_ARGS[@]}" < "$PROMPT_FILE" 2>&1 | tee /dev/stderr) || true
  elif [[ "$TOOL" == "gemini" ]]; then
    # Gemini CLI has no effort knob; --approval-mode yolo is the current spelling
    # of the old -y/--yolo flag.
    GEMINI_ARGS=(--approval-mode yolo)
    [[ -n "$MODEL" ]] && GEMINI_ARGS+=(--model "$MODEL")
    OUTPUT=$(gemini "${GEMINI_ARGS[@]}" --prompt "$(<"$PROMPT_FILE")" 2>&1 | tee /dev/stderr) || true
  else
    # Codex has no --effort flag: reasoning effort is a config key, overridden
    # per-run with -c. Only sent when the user asked for one, so the value in
    # ~/.codex/config.toml stays authoritative otherwise.
    CODEX_ARGS=(exec --dangerously-bypass-approvals-and-sandbox -C "$PROJECT_ROOT")
    [[ -n "$MODEL" ]] && CODEX_ARGS+=(--model "$MODEL")
    [[ "$EFFORT_EXPLICIT" -eq 1 ]] && CODEX_ARGS+=(-c "model_reasoning_effort=\"$EFFORT\"")
    OUTPUT=$(codex "${CODEX_ARGS[@]}" - < "$PROMPT_FILE" 2>&1 | tee /dev/stderr) || true
  fi
  
  # Check for completion signal
  if echo "$OUTPUT" | grep -q "<promise>COMPLETE</promise>"; then
    echo ""
    echo "Ralph completed all tasks!"
    echo "Completed at iteration $i of $MAX_ITERATIONS"
    exit 0
  fi
  
  echo "Iteration $i complete. Continuing..."
  sleep 2
done

echo ""
echo "Ralph reached max iterations ($MAX_ITERATIONS) without completing all tasks."
echo "Check $PROGRESS_FILE for status."
exit 1
