#!/bin/bash
# Ralph Wiggum - Long-running AI agent loop
# Usage: ralph [--tool amp|claude|gemini|codex] [max_iterations]

set -euo pipefail

print_usage() {
  cat <<'EOF'
Usage: ralph [--tool claude|codex|agy|cursor|opencode|amp|gemini] [--model MODEL]
             [--effort low|medium|high|xhigh|max] [max_iterations]

Options:
  --tool TOOL        Agent to run. Supported: claude, codex, agy, cursor,
                     opencode, amp, gemini
  --tool=TOOL        Same as above
  --claude           Shortcut for --tool claude
  --codex            Shortcut for --tool codex
  --agy              Shortcut for --tool agy       (Antigravity)
  --cursor           Shortcut for --tool cursor    (cursor-agent)
  --opencode         Shortcut for --tool opencode
  --amp              Shortcut for --tool amp
  --gemini           Shortcut for --tool gemini    (superseded by agy)
  --model MODEL      Model to run, by hand. Defaults to the tool's own configured
                     model. Soft-checked against what the tool advertises.
  --model=MODEL      Same as above
  --list-models      Show, per tool, its configured model, the models it
                     advertises, and the effort levels it accepts. Queries the
                     installed CLIs rather than a table baked into Ralph.
  --effort LEVEL     Reasoning effort: low, medium, high, xhigh, max. Ralph takes
                     one vocabulary and translates it per tool — a flag for
                     claude and agy, a config key for codex, a bracket override
                     on the model for cursor, --variant for opencode. A level the
                     chosen tool does not accept is an error, not a downgrade.
                     Default: medium.
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

SUPPORTED_TOOLS="amp claude codex agy cursor opencode gemini"

# opencode installs to ~/.opencode/bin and does not always land on PATH.
resolve_opencode_bin() {
  if command -v opencode >/dev/null 2>&1; then
    command -v opencode
    return 0
  fi
  if [[ -x "$HOME/.opencode/bin/opencode" ]]; then
    echo "$HOME/.opencode/bin/opencode"
    return 0
  fi
  return 1
}

# Reasoning effort, per tool.
#
# Ralph takes one vocabulary from the user — low, medium, high, xhigh, max — and
# hands each tool the spelling and the mechanism that tool actually wants. They
# do not agree on any of it: claude has a flag, codex has a config key, cursor
# encodes it inside the model string, agy has a flag with a narrower range, and
# amp has nothing.
#
# Every list below came from the CLI itself, not from a vendor page:
#
#   claude  `claude --effort bogus` answers
#           "Valid values: low, medium, high, xhigh, max."
#   agy     `agy --help` documents "--effort  Reasoning effort for the current
#           CLI session (low|medium|high)"
#   codex   `codex exec -c model_reasoning_effort=bogus` is accepted and
#           forwarded verbatim — the CLI does no validation at all, so the list
#           here is Ralph's own guard rather than an echo of the tool's.
#   cursor  `cursor-agent --help` shows effort as a bracket override on the
#           model: 'claude-opus-4-8[context=1m,effort=high,fast=false]'. Only
#           `effort=high` is exemplified, so Ralph accepts its own vocabulary
#           and lets Cursor reject server-side rather than inventing an enum.
#   opencode
#           `opencode run --help` documents "--variant  model variant
#           (provider-specific reasoning effort, e.g., high, max, minimal)".
#           Provider-specific by definition, so the same passthrough applies.
tool_effort_values() {
  case "$1" in
    claude)   echo "low medium high xhigh max" ;;
    agy)      echo "low medium high" ;;
    codex)    echo "minimal low medium high xhigh" ;;
    cursor)   echo "low medium high xhigh max" ;;
    opencode) echo "minimal low medium high max" ;;
  esac
}

tool_supports_effort() {
  [[ -n "$(tool_effort_values "$1")" ]]
}

tool_effort_mechanism() {
  case "$1" in
    claude)   echo "--effort flag" ;;
    agy)      echo "--effort flag" ;;
    codex)    echo "model_reasoning_effort config key" ;;
    cursor)   echo "effort= override inside --model" ;;
    opencode) echo "--variant flag" ;;
    *)        echo "not supported by this CLI" ;;
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

# Two of these CLIs can enumerate their own models; the rest cannot. Ask the
# ones that can, parse the one that documents aliases in its help text, and
# report honestly for the rest instead of shipping a table that goes stale.
#
# Both listing commands need the user signed in. A signed-out CLI answers with
# an auth error, which is not a model list — so it returns nothing and Ralph
# falls back to passing --model through unvalidated.
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
    agy)
      command -v agy >/dev/null 2>&1 || return 0
      agy models 2>/dev/null \
        | grep -vEi 'fetching|error|sign in|log in' \
        | grep -Eo '[a-zA-Z0-9][a-zA-Z0-9._-]{2,}' \
        | sort -u \
        | tr '\n' ' '
      ;;
    cursor)
      command -v cursor-agent >/dev/null 2>&1 || return 0
      cursor-agent --list-models 2>/dev/null \
        | grep -vEi 'error|authentication|login|api-key' \
        | grep -Eo '[a-zA-Z0-9][a-zA-Z0-9._-]{2,}' \
        | sort -u \
        | tr '\n' ' '
      ;;
    opencode)
      local bin
      bin="$(resolve_opencode_bin)" || return 0
      # The only one of these that answers without being signed in, and the
      # only one whose ids are already provider-qualified.
      "$bin" models 2>/dev/null \
        | grep -E '^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$' \
        | sort -u \
        | tr '\n' ' '
      ;;
  esac
}

# Cursor has no --effort flag: effort rides inside the model string as a bracket
# override. Composing it needs a model to attach to, so --effort without --model
# has nothing to modify.
cursor_model_argument() {
  local model="$1" effort_explicit="$2" effort="$3"

  if [[ "$effort_explicit" -eq 1 ]]; then
    if [[ -z "$model" ]]; then
      return 1
    fi
    if [[ "$model" == *"["*"]" ]]; then
      # Caller already wrote their own override block — respect it verbatim
      # rather than producing a second one Cursor would have to reconcile.
      printf '%s' "$model"
      return 0
    fi
    printf '%s[effort=%s]' "$model" "$effort"
    return 0
  fi

  printf '%s' "$model"
}

# The tool name is not always the binary name: cursor ships `cursor-agent`, and
# opencode installs outside PATH.
tool_binary_path() {
  case "$1" in
    cursor)   command -v cursor-agent 2>/dev/null ;;
    opencode) resolve_opencode_bin ;;
    *)        command -v "$1" 2>/dev/null ;;
  esac
}

print_models() {
  local tool configured advertised installed

  echo "Models"
  echo ""
  for tool in $SUPPORTED_TOOLS; do
    if tool_binary_path "$tool" >/dev/null 2>&1; then
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
      printf '    effort             : %s  (via %s)\n' \
        "$(tool_effort_values "$tool")" "$(tool_effort_mechanism "$tool")"
    else
      printf '    effort             : not supported by this CLI\n'
    fi
    echo ""
  done
  cat <<'EOF'
--model is passed to the tool as given. Where a CLI can enumerate its models,
Ralph warns on a value that is not in the list but still runs it — a full model
id is often valid without being advertised.

--effort takes one vocabulary (low, medium, high, xhigh, max) and Ralph
translates it per tool. A level the chosen tool does not accept is an error, not
a silent downgrade.

With no --model, each tool uses its own configured default rather than one Ralph
picked for you.
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
    --agy)
      TOOL="agy"
      shift
      ;;
    --cursor)
      TOOL="cursor"
      shift
      ;;
    --opencode)
      TOOL="opencode"
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
case " $SUPPORTED_TOOLS " in
  *" $TOOL "*) ;;
  *)
    echo "Error: Invalid tool '$TOOL'. Must be one of: $SUPPORTED_TOOLS."
    exit 1
    ;;
esac

# Effort is validated against what the chosen tool accepts, not against a single
# global list. A level one tool understands and another does not is an error
# here rather than a silent downgrade at the far end.
if [[ "$EFFORT_EXPLICIT" -eq 1 ]]; then
  TOOL_EFFORTS="$(tool_effort_values "$TOOL")"
  if [[ -z "$TOOL_EFFORTS" ]]; then
    echo "Error: --effort is not supported by '$TOOL'."
    echo "       Run 'ralph --list-models' to see what each installed tool exposes."
    exit 1
  fi
  case " $TOOL_EFFORTS " in
    *" $EFFORT "*) ;;
    *)
      echo "Error: '$TOOL' does not accept effort '$EFFORT'."
      echo "       Accepts: $TOOL_EFFORTS  (via $(tool_effort_mechanism "$TOOL"))"
      exit 1
      ;;
  esac
  if [[ "$TOOL" == "cursor" && -z "$MODEL" ]]; then
    echo "Error: cursor carries effort inside the model string, so --effort needs --model."
    echo "       Example: ralph --cursor --model sonnet-4-thinking --effort high"
    exit 1
  fi
fi

# Model is only soft-checked. Where a CLI can enumerate its models, a value
# outside that list is worth flagging — but a full model id is frequently valid
# without being advertised, so this warns and runs rather than refusing.
if [[ -n "$MODEL" ]]; then
  KNOWN_MODELS="$(tool_advertised_models "$TOOL" || true)"
  if [[ -n "${KNOWN_MODELS// /}" ]]; then
    case " $KNOWN_MODELS " in
      *" $MODEL "*) ;;
      *)
        echo "Warning: '$MODEL' is not in the model list '$TOOL' advertises."
        echo "         Known: ${KNOWN_MODELS% }"
        echo "         Running it anyway — the tool has the final say."
        ;;
    esac
  fi
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

if [[ "$TOOL" == "agy" ]] && ! command -v agy >/dev/null 2>&1; then
  echo "Error: agy (Antigravity) is required but was not found in PATH."
  exit 1
fi

if [[ "$TOOL" == "cursor" ]] && ! command -v cursor-agent >/dev/null 2>&1; then
  echo "Error: cursor-agent is required but was not found in PATH."
  exit 1
fi

if [[ "$TOOL" == "opencode" ]]; then
  OPENCODE_BIN="$(resolve_opencode_bin)" || {
    echo "Error: opencode was not found in PATH or at ~/.opencode/bin/opencode."
    exit 1
  }
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
AGY_PROMPT_FILE_NAME="AGY.md"
CURSOR_PROMPT_FILE_NAME="CURSOR.md"
OPENCODE_PROMPT_FILE_NAME="OPENCODE.md"

case "$TOOL" in
  claude)   PROMPT_FILE_NAME="$CLAUDE_PROMPT_FILE_NAME" ;;
  gemini)   PROMPT_FILE_NAME="$GEMINI_PROMPT_FILE_NAME" ;;
  codex)    PROMPT_FILE_NAME="$CODEX_PROMPT_FILE_NAME" ;;
  amp)      PROMPT_FILE_NAME="$AMP_PROMPT_FILE_NAME" ;;
  agy)      PROMPT_FILE_NAME="$AGY_PROMPT_FILE_NAME" ;;
  cursor)   PROMPT_FILE_NAME="$CURSOR_PROMPT_FILE_NAME" ;;
  opencode) PROMPT_FILE_NAME="$OPENCODE_PROMPT_FILE_NAME" ;;
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
  elif [[ "$TOOL" == "agy" ]]; then
    # Antigravity: same shape as claude — --print reads the prompt from stdin.
    AGY_ARGS=(--print --dangerously-skip-permissions)
    [[ -n "$MODEL" ]] && AGY_ARGS+=(--model "$MODEL")
    [[ "$EFFORT_EXPLICIT" -eq 1 ]] && AGY_ARGS+=(--effort "$EFFORT")
    OUTPUT=$(agy "${AGY_ARGS[@]}" < "$PROMPT_FILE" 2>&1 | tee /dev/stderr) || true
  elif [[ "$TOOL" == "cursor" ]]; then
    # cursor-agent takes the prompt as a positional argument, and carries effort
    # inside the model string rather than as its own flag.
    CURSOR_ARGS=(--print --force)
    CURSOR_MODEL="$(cursor_model_argument "$MODEL" "$EFFORT_EXPLICIT" "$EFFORT")"
    [[ -n "$CURSOR_MODEL" ]] && CURSOR_ARGS+=(--model "$CURSOR_MODEL")
    OUTPUT=$(cursor-agent "${CURSOR_ARGS[@]}" "$(<"$PROMPT_FILE")" 2>&1 | tee /dev/stderr) || true
  elif [[ "$TOOL" == "opencode" ]]; then
    # opencode run takes the prompt positionally; effort is --variant, and model
    # ids are provider-qualified (provider/model).
    OPENCODE_ARGS=(run --auto)
    [[ -n "$MODEL" ]] && OPENCODE_ARGS+=(--model "$MODEL")
    [[ "$EFFORT_EXPLICIT" -eq 1 ]] && OPENCODE_ARGS+=(--variant "$EFFORT")
    OUTPUT=$("$OPENCODE_BIN" "${OPENCODE_ARGS[@]}" "$(<"$PROMPT_FILE")" 2>&1 | tee /dev/stderr) || true
  elif [[ "$TOOL" == "gemini" ]]; then
    # Gemini CLI has no effort knob; --approval-mode yolo is the current spelling
    # of the old -y/--yolo flag. Superseded by agy (Antigravity) — kept for
    # anyone still on gemini-cli.
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
